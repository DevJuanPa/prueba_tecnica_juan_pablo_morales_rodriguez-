-- ============================================================================
-- BLOQUE 1 · SQL AVANZADO
-- Dialecto: BigQuery Standard SQL
-- Dataset asumido: `retail.transactions`, `retail.transaction_items`,
--                   `retail.stores`, `retail.products`, `retail.vendors`,
--                   `retail.store_promotions`
--
-- DECISIONES HEREDADAS DEL BLOQUE 0 (auditoría), aplicadas en todas las
-- queries donde corresponde:
--   1. GMV se calcula SIEMPRE desde transaction_items (unit_price*quantity),
--      no desde transactions.total_amount, por la discrepancia del 1% hallada.
--   2. TIENDA_037 se excluye de Comp Sales / antigüedad de tienda (Query 1)
--      por tener transacciones antes de su opening_date.
--   3. TIENDA_008 y TIENDA_037 se excluyen del análisis A/B (Bloque 3, no aquí).
--   4. Líneas con unit_price = 0 y was_on_promo = FALSE se excluyen de
--      cálculos de ticket promedio / GMROI (distorsionan promedios).
--   5. Productos con vendor_id huérfano se excluyen de GMROI por vendor.
-- ============================================================================


-- ============================================================================
-- QUERY 1: Ventas comparables (Comp Sales) YoY
-- ============================================================================
-- Definición de "comparable": la tienda debe llevar operando al menos 13 meses
-- respecto a la fecha de corte del dataset (2025-06-30), siguiendo la
-- definición estándar de retail (NRF). Cutoff = 2025-06-30 - 13 meses = 2024-05-30.
-- Período comparado: el único semestre con datos completos en ambos años
-- (ene-jun), ya que el dataset solo cubre hasta junio 2025.

WITH params AS (
  SELECT
    DATE '2025-01-01' AS curr_start, DATE '2025-06-30' AS curr_end,
    DATE '2024-01-01' AS prior_start, DATE '2024-06-30' AS prior_end,
    DATE '2024-05-30' AS eligibility_cutoff   -- 13 meses antes del máximo de datos
),

eligible_stores AS (
  -- Tiendas con al menos 13 meses de antigüedad y sin problemas de integridad
  -- temporal detectados en la auditoría (TIENDA_037 excluida).
  SELECT s.*
  FROM `retail.stores` s, params p
  WHERE s.opening_date <= p.eligibility_cutoff
    AND s.store_id != 'TIENDA_037'
),

clean_sales AS (
  SELECT
    t.store_id,
    t.transaction_date,
    ti.unit_price * ti.quantity AS line_gmv
  FROM `retail.transaction_items` ti
  JOIN `retail.transactions` t USING (transaction_id)
  WHERE t.status = 'COMPLETED'      -- devoluciones no suman a GMV bruto de comp sales
),

store_period_gmv AS (
  SELECT
    cs.store_id,
    SUM(IF(cs.transaction_date BETWEEN p.curr_start AND p.curr_end, cs.line_gmv, 0)) AS gmv_current,
    SUM(IF(cs.transaction_date BETWEEN p.prior_start AND p.prior_end, cs.line_gmv, 0)) AS gmv_prior
  FROM clean_sales cs, params p
  GROUP BY cs.store_id
),

comp AS (
  SELECT
    es.store_id,
    es.store_name,
    es.country,
    es.format,
    spg.gmv_current,
    spg.gmv_prior,
    SAFE_DIVIDE(spg.gmv_current - spg.gmv_prior, spg.gmv_prior) * 100 AS comp_growth_pct
  FROM eligible_stores es
  JOIN store_period_gmv spg USING (store_id)
)

-- 1a) Resumen por país y formato
SELECT
  country,
  format,
  COUNT(DISTINCT store_id) AS num_tiendas_comparables,
  ROUND(SUM(gmv_current), 2) AS gmv_actual,
  ROUND(SUM(gmv_prior), 2) AS gmv_anterior,
  ROUND(SAFE_DIVIDE(SUM(gmv_current) - SUM(gmv_prior), SUM(gmv_prior)) * 100, 2) AS comp_sales_growth_pct
FROM comp
GROUP BY country, format
ORDER BY country, format;

-- 1b) Ranking de tiendas por crecimiento dentro de su formato
SELECT
  country,
  format,
  store_id,
  store_name,
  ROUND(gmv_current, 2) AS gmv_actual,
  ROUND(gmv_prior, 2) AS gmv_anterior,
  ROUND(comp_growth_pct, 2) AS comp_growth_pct,
  RANK() OVER (PARTITION BY format ORDER BY comp_growth_pct DESC) AS rank_en_formato
FROM comp
ORDER BY format, rank_en_formato;


-- ============================================================================
-- QUERY 2: Productividad por metro cuadrado (último trimestre)
-- ============================================================================
-- "Último trimestre" = 2025 Q2 (abr-jun 2025), el trimestre completo más
-- reciente en el dataset (los datos terminan 2025-06-30).

WITH last_quarter AS (
  SELECT DATE '2025-04-01' AS q_start, DATE '2025-06-30' AS q_end
),

quarter_sales AS (
  SELECT
    t.store_id,
    t.transaction_id,
    ti.unit_price * ti.quantity AS line_gmv
  FROM `retail.transaction_items` ti
  JOIN `retail.transactions` t USING (transaction_id)
  CROSS JOIN last_quarter lq
  WHERE t.status = 'COMPLETED'
    AND t.transaction_date BETWEEN lq.q_start AND lq.q_end
),

store_metrics AS (
  SELECT
    s.store_id,
    s.store_name,
    s.country,
    s.format,
    s.size_sqm,
    ROUND(SUM(qs.line_gmv), 2) AS gmv_trimestre,
    COUNT(DISTINCT qs.transaction_id) AS num_transacciones,
    ROUND(SUM(qs.line_gmv) / s.size_sqm, 2) AS gmv_por_sqm,
    ROUND(COUNT(DISTINCT qs.transaction_id) / s.size_sqm, 4) AS transacciones_por_sqm,
    ROUND(SUM(qs.line_gmv) / NULLIF(COUNT(DISTINCT qs.transaction_id), 0), 2) AS ticket_promedio
  FROM `retail.stores` s
  LEFT JOIN quarter_sales qs USING (store_id)
  GROUP BY s.store_id, s.store_name, s.country, s.format, s.size_sqm
),

with_percentile AS (
  SELECT
    *,
    PERCENTILE_CONT(gmv_por_sqm, 0.25) OVER (PARTITION BY format) AS p25_gmv_por_sqm,
    RANK() OVER (PARTITION BY format ORDER BY gmv_por_sqm DESC) AS rank_en_formato
  FROM store_metrics
)

SELECT
  country,
  format,
  store_id,
  store_name,
  gmv_trimestre,
  gmv_por_sqm,
  transacciones_por_sqm,
  ticket_promedio,
  rank_en_formato,
  IF(gmv_por_sqm < p25_gmv_por_sqm, 'BAJO_RENDIMIENTO', 'OK') AS flag_rendimiento
FROM with_percentile
ORDER BY format, rank_en_formato;


-- ============================================================================
-- QUERY 3: Cohortes de clientes con tarjeta de lealtad
-- ============================================================================
-- Solo clientes identificados (loyalty_card = TRUE). Cohorte = mes calendario
-- de la primera transacción. Se calcula tamaño de cohorte, % retenido en los
-- meses 1/2/3/6 desde el mes de adquisición, y ticket promedio por período.

WITH loyalty_tx AS (
  SELECT
    t.customer_id,
    t.transaction_id,
    t.transaction_date,
    DATE_TRUNC(t.transaction_date, MONTH) AS tx_month,
    ti.unit_price * ti.quantity AS line_gmv
  FROM `retail.transactions` t
  JOIN `retail.transaction_items` ti USING (transaction_id)
  WHERE t.loyalty_card = TRUE
    AND t.status = 'COMPLETED'
),

customer_first_month AS (
  SELECT customer_id, MIN(tx_month) AS cohort_month
  FROM loyalty_tx
  GROUP BY customer_id
),

customer_activity AS (
  SELECT
    lt.customer_id,
    cfm.cohort_month,
    lt.tx_month,
    DATE_DIFF(lt.tx_month, cfm.cohort_month, MONTH) AS month_offset,
    lt.transaction_id,
    lt.line_gmv
  FROM loyalty_tx lt
  JOIN customer_first_month cfm USING (customer_id)
),

cohort_size AS (
  SELECT cohort_month, COUNT(DISTINCT customer_id) AS cohort_customers
  FROM customer_first_month
  GROUP BY cohort_month
),

retention_by_offset AS (
  SELECT
    cohort_month,
    month_offset,
    COUNT(DISTINCT customer_id) AS activos,
    ROUND(SUM(line_gmv) / COUNT(DISTINCT transaction_id), 2) AS ticket_promedio_periodo
  FROM customer_activity
  WHERE month_offset IN (0, 1, 2, 3, 6)
  GROUP BY cohort_month, month_offset
)

-- Tabla pivoteada: cohortes en filas, meses (0/1/2/3/6) en columnas.
-- % retención = activos en el mes offset / tamaño de cohorte.
SELECT
  cs.cohort_month,
  cs.cohort_customers,
  ROUND(MAX(IF(r.month_offset = 1, r.activos, NULL)) / cs.cohort_customers * 100, 1) AS retencion_mes1_pct,
  ROUND(MAX(IF(r.month_offset = 2, r.activos, NULL)) / cs.cohort_customers * 100, 1) AS retencion_mes2_pct,
  ROUND(MAX(IF(r.month_offset = 3, r.activos, NULL)) / cs.cohort_customers * 100, 1) AS retencion_mes3_pct,
  ROUND(MAX(IF(r.month_offset = 6, r.activos, NULL)) / cs.cohort_customers * 100, 1) AS retencion_mes6_pct,
  MAX(IF(r.month_offset = 0, r.ticket_promedio_periodo, NULL)) AS ticket_mes0,
  MAX(IF(r.month_offset = 1, r.ticket_promedio_periodo, NULL)) AS ticket_mes1,
  MAX(IF(r.month_offset = 3, r.ticket_promedio_periodo, NULL)) AS ticket_mes3,
  MAX(IF(r.month_offset = 6, r.ticket_promedio_periodo, NULL)) AS ticket_mes6
FROM cohort_size cs
LEFT JOIN retention_by_offset r USING (cohort_month)
GROUP BY cs.cohort_month, cs.cohort_customers
ORDER BY cs.cohort_month;


-- ============================================================================
-- QUERY 4: GMROI por proveedor y categoría
-- ============================================================================
-- GMROI = Margen Bruto / Costo Total. Se excluyen los 5 productos con
-- vendor_id huérfano (hallazgo de integridad referencial, Bloque 0).

WITH valid_products AS (
  SELECT p.*
  FROM `retail.products` p
  JOIN `retail.vendors` v USING (vendor_id)   -- INNER JOIN descarta huérfanos
),

sales_detail AS (
  SELECT
    vp.vendor_id,
    v.vendor_name,
    vp.category,
    vp.item_id,
    ti.quantity,
    ti.unit_price * ti.quantity AS line_gmv,
    vp.cost * ti.quantity AS line_cost,
    t.transaction_date
  FROM `retail.transaction_items` ti
  JOIN `retail.transactions` t USING (transaction_id)
  JOIN valid_products vp ON ti.item_id = vp.item_id
  JOIN `retail.vendors` v ON vp.vendor_id = v.vendor_id
  WHERE t.status = 'COMPLETED'
),

date_range AS (
  SELECT DATE_DIFF(MAX(transaction_date), MIN(transaction_date), DAY) + 1 AS total_dias
  FROM sales_detail
)

SELECT
  sd.vendor_id,
  sd.vendor_name,
  sd.category,
  ROUND(SUM(sd.line_gmv), 2) AS gmv,
  ROUND(SUM(sd.line_cost), 2) AS costo_total,
  ROUND(SUM(sd.line_gmv) - SUM(sd.line_cost), 2) AS margen_bruto,
  ROUND(SAFE_DIVIDE(SUM(sd.line_gmv) - SUM(sd.line_cost), SUM(sd.line_cost)), 2) AS gmroi,
  COUNT(DISTINCT sd.item_id) AS skus_activos,
  ROUND(SUM(sd.quantity) / dr.total_dias, 2) AS velocidad_unidades_dia,
  IF(SAFE_DIVIDE(SUM(sd.line_gmv) - SUM(sd.line_cost), SUM(sd.line_cost)) < 1, 'ALERTA_GMROI_BAJO', 'OK') AS flag_gmroi
FROM sales_detail sd
CROSS JOIN date_range dr
GROUP BY sd.vendor_id, sd.vendor_name, sd.category, dr.total_dias
ORDER BY gmroi ASC;


-- ============================================================================
-- QUERY 5: Detección de posibles quiebres de stock
-- ============================================================================
-- Un ítem tiene un posible quiebre si pasó >= 3 días consecutivos sin venta
-- en una tienda donde históricamente sí se vendía (definimos "históricamente
-- vendido" como al menos 5 días distintos con venta en esa tienda, para
-- descartar ítems de venta esporádica/anecdótica que generarían falsos gaps).
--
-- NOTA METODOLÓGICA (validado con muestra en pandas): con 200 SKUs en 40
-- tiendas y 546 días, cada par tienda-ítem vende en promedio solo ~20% de los
-- días del período. Esto genera muchos gaps de 3+ días que son rotación baja
-- normal, no necesariamente quiebre real. Por eso el resultado se ordena por
-- GMV estimado perdido DESC: el negocio debe priorizar el top N de mayor
-- impacto económico, no tratar cada gap como incidente equivalente.

WITH item_store_sales AS (
  SELECT DISTINCT
    t.store_id,
    ti.item_id,
    t.transaction_date AS sale_date
  FROM `retail.transaction_items` ti
  JOIN `retail.transactions` t USING (transaction_id)
  WHERE t.status = 'COMPLETED'
),

qualifying_pairs AS (
  -- Solo tienda-ítem con historial de venta real (>=5 días distintos)
  SELECT store_id, item_id
  FROM item_store_sales
  GROUP BY store_id, item_id
  HAVING COUNT(DISTINCT sale_date) >= 5
),

sales_with_lag AS (
  SELECT
    iss.store_id,
    iss.item_id,
    iss.sale_date,
    LEAD(iss.sale_date) OVER (
      PARTITION BY iss.store_id, iss.item_id ORDER BY iss.sale_date
    ) AS next_sale_date
  FROM item_store_sales iss
  JOIN qualifying_pairs qp USING (store_id, item_id)
),

gaps AS (
  SELECT
    store_id,
    item_id,
    sale_date AS gap_start_after,
    next_sale_date AS gap_end_before,
    DATE_DIFF(next_sale_date, sale_date, DAY) - 1 AS gap_duration_days
  FROM sales_with_lag
  WHERE DATE_DIFF(next_sale_date, sale_date, DAY) - 1 >= 3
),

pre_gap_velocity AS (
  -- Ventas promedio diarias de ese ítem/tienda en los 14 días previos al gap
  SELECT
    g.store_id,
    g.item_id,
    g.gap_start_after,
    g.gap_end_before,
    g.gap_duration_days,
    ROUND(AVG(ti.quantity), 2) AS avg_unidades_dia_previo,
    ROUND(AVG(ti.unit_price), 2) AS precio_promedio_previo
  FROM gaps g
  JOIN `retail.transactions` t
    ON t.store_id = g.store_id
    AND t.transaction_date BETWEEN DATE_SUB(g.gap_start_after, INTERVAL 14 DAY) AND g.gap_start_after
  JOIN `retail.transaction_items` ti
    ON ti.transaction_id = t.transaction_id AND ti.item_id = g.item_id
  GROUP BY g.store_id, g.item_id, g.gap_start_after, g.gap_end_before, g.gap_duration_days
)

SELECT
  pgv.store_id,
  pgv.item_id,
  p.category,
  pgv.gap_start_after AS ultima_venta_antes_del_gap,
  pgv.gap_end_before AS primera_venta_despues_del_gap,
  pgv.gap_duration_days,
  pgv.avg_unidades_dia_previo,
  ROUND(pgv.avg_unidades_dia_previo * pgv.gap_duration_days * pgv.precio_promedio_previo, 2) AS gmv_estimado_perdido
FROM pre_gap_velocity pgv
JOIN `retail.products` p USING (item_id)
ORDER BY gmv_estimado_perdido DESC;


-- ============================================================================
-- QUERY 6: Impacto de promociones en ticket y volumen (basket analysis)
-- ============================================================================
-- Compara, por categoría, transacciones que contienen AL MENOS un ítem en
-- promo vs transacciones que no contienen ningún ítem en promo.

WITH tx_promo_flag AS (
  -- Marca cada transacción como "con promo" si tiene >=1 línea en promo,
  -- por categoría (una transacción puede tener items de varias categorías)
  SELECT
    t.transaction_id,
    p.category,
    MAX(IF(ti.was_on_promo, 1, 0)) AS tiene_promo_en_categoria,
    SUM(ti.unit_price * ti.quantity) AS gmv_categoria_en_tx,
    SUM(ti.quantity) AS unidades_categoria_en_tx
  FROM `retail.transaction_items` ti
  JOIN `retail.transactions` t USING (transaction_id)
  JOIN `retail.products` p USING (item_id)
  WHERE t.status = 'COMPLETED'
  GROUP BY t.transaction_id, p.category
)

SELECT
  category,
  tiene_promo_en_categoria,
  COUNT(DISTINCT transaction_id) AS num_transacciones,
  ROUND(AVG(gmv_categoria_en_tx), 2) AS ticket_promedio,
  ROUND(AVG(unidades_categoria_en_tx), 2) AS unidades_promedio,
  ROUND(
    AVG(gmv_categoria_en_tx) - LAG(AVG(gmv_categoria_en_tx)) OVER (PARTITION BY category ORDER BY tiene_promo_en_categoria),
    2
  ) AS diferencia_ticket_vs_sin_promo
FROM tx_promo_flag
GROUP BY category, tiene_promo_en_categoria
ORDER BY category, tiene_promo_en_categoria;

-- Interpretación esperada (para bloque3_analisis): si unidades_promedio sube
-- significativamente en promo Y ticket_promedio sube (no solo compensa el
-- descuento), hay basket uplift real. Si el ticket cae proporcional al
-- descuento sin subir unidades, es solo canibalización/descuento en lo que
-- ya se iba a comprar.
