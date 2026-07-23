# Bloque 2 — Decisiones de Diseño, Pipeline ETL y Gobernanza

## A. Modelo Dimensional — Justificación de decisiones de diseño

El modelo completo está en `bloque2_modelo.pdf` (Star Schema). Aquí se justifican las
decisiones más importantes:

### Decisión 1 — Grano del fact table: línea de ítem, no transacción

`FACT_SALES_LINE` tiene grano de **1 fila = 1 línea de `transaction_item`**, no 1 fila por
transacción. Se descartó modelar al grano de transacción porque:
- GMROI (Query 4) y el análisis de promociones (Query 6) necesitan el detalle por
  ítem/categoría, que se perdería al agregar a nivel de transacción.
- Las métricas de transacción (ticket promedio, # transacciones) se derivan fácilmente
  agregando el fact (`COUNT(DISTINCT transaction_id)`, `SUM(line_gmv)/COUNT(DISTINCT
  transaction_id)`), pero lo inverso (desagregar una transacción a sus ítems) no es posible
  si no se guarda el detalle.
- Es el estándar en modelado dimensional de retail: capturar el grano más fino disponible y
  agregar hacia arriba, nunca al revés.

### Decisión 2 — Cómo modelar que el 60% de transacciones no tiene `customer_id`

En vez de dejar `customer_key` como NULL en el fact (lo cual rompe INNER JOINs y complica
cualquier reporte que cruce con `dim_customer`), se usa la técnica estándar de **fila
"Unknown Member"**: se crea un registro en `dim_customer` con `customer_key = -1`,
`customer_id = NULL`, `is_identified = FALSE`. Todas las transacciones sin tarjeta de
lealtad apuntan a esa fila.

Ventajas de esta decisión:
- Todos los JOINs entre `fact_sales` y `dim_customer` pueden ser INNER JOIN (más eficientes
  en BigQuery, sin necesidad de LEFT JOIN defensivos en cada query).
- El campo `is_identified` permite filtrar fácilmente "solo clientes identificados" para el
  análisis de cohortes (Query 3) sin tener que acordarse de excluir NULLs cada vez.
- Evita que un analista calcule por error un "cliente promedio" que mezcle el 60% de tráfico
  anónimo con el 40% identificado.

### Decisión 3 — Costo histórico capturado en el fact, no solo en la dimensión

`FACT_SALES_LINE` incluye `cost_at_sale` (el costo del producto al momento de la venta),
además de que `DIM_PRODUCT` tiene `current_cost`. Esto es una decisión deliberada pensando
en un pipeline real (no solo en el dataset sintético actual, donde el costo es estático):
- Si el costo de un producto cambia con el tiempo (negociación con proveedor, inflación,
  etc.), un `dim_product` de tipo SCD-1 (sobrescribe el valor) recalcularía mal el GMROI
  histórico si se recalculara con el costo actual.
- Guardar `cost_at_sale` en el fact congela el margen histórico real de cada venta, que es
  lo correcto para reportes financieros de periodos pasados.
- `current_cost` en la dimensión queda disponible para simulaciones ("si el precio actual
  se aplicara al histórico"), pero no se usa para el GMROI reportado oficialmente.

### Decisión 4 — Promociones/A-B test como factless fact, no como FK directo en fact_sales

`FACT_STORE_EXPERIMENT_ASSIGNMENT` es una tabla de hechos sin métricas (factless fact) con
grano tienda × experimento × rango de fechas, separada de `FACT_SALES_LINE`. No se agregó un
`promo_key` directamente a `fact_sales_line` porque:
- La asignación CONTROL/TREATMENT es a nivel **tienda + rango de fechas**, no a nivel de
  línea de venta o producto — mezclar ambos grados en la misma fila generaría fan-out
  (una venta podría "pertenecer" a 0, 1 o más experimentos según su fecha).
- Al mantenerlo separado, el join entre ventas y experimento se hace explícitamente por
  `store_id` + `transaction_date BETWEEN start_date AND end_date` solo cuando se necesita
  analizar el A/B test, sin inflar el fact principal con columnas que el 90% de las queries
  no usa.
- Esta tabla también deja evidencia explícita y auditable de la doble asignación de
  TIENDA_008 y TIENDA_037 detectada en el Bloque 0 (aparecen dos filas para la misma tienda
  con variantes distintas), en vez de ocultar el problema con un solo campo.

### Decisión 5 — Particionamiento y clustering en BigQuery

`FACT_SALES_LINE` se particiona por `date_key` (partición diaria nativa de BigQuery) y se
clusteriza por `store_key, product_key`. Con 542K filas hoy pero un pipeline que va a seguir
creciendo, esto:
- Reduce el costo/escaneo de las queries de Bloque 1 que casi siempre filtran por rango de
  fechas (Comp Sales, productividad trimestral).
- El clustering por tienda acelera los rankings/agregaciones por tienda que se repiten en
  casi todas las queries del negocio (dashboards regionales).

---

## B. Diseño del Pipeline ETL/ELT

### ¿Cómo manejar que las tiendas reportan con hasta 2 horas de retraso?

Se diseña el pipeline en dos capas:
1. **Capa de staging (raw/landing)**: ingesta continua (micro-batch cada 30-60 min) que
   simplemente aterriza lo que llega, sin transformar. No se asume que el día está "cerrado".
2. **Capa curada (fact_sales)**: el job de consolidación diaria **no corre antes de las 2:30
   AM del día siguiente**, dejando un margen de seguridad de 30 min sobre el retraso máximo
   conocido (2h). Esto evita cerrar el día con datos incompletos.

Si se necesita un dashboard "casi en tiempo real" además del diario, se puede exponer una
vista sobre staging marcada explícitamente como "datos preliminares, sujetos a ajuste" —
nunca mezclada con la capa curada/certificada.

### ¿Cómo detectar automáticamente que una tienda dejó de enviar datos?

Un job de monitoreo (corre junto con la consolidación diaria) calcula, por tienda, la fecha
de la última transacción cargada vs. la fecha esperada (ayer). Si una tienda no tiene
registros para el día anterior pasado el SLA de las 2:30 AM + margen, se dispara una alerta
(Cloud Monitoring / Slack / email al equipo de Operaciones de esa tienda). Esta es
exactamente la misma lógica de "frescura" aplicada en la auditoría del Bloque 0
(`TIENDA_012` con gap de 8 días), pero corriendo de forma automática y diaria en vez de
manual y retrospectiva.

### ¿Cómo hacer cargas incrementales sin duplicar transacciones?

- `transaction_id` es la llave natural e inmutable (confirmado 0 duplicados en la auditoría).
- Se usa `MERGE INTO fact_sales USING staging_batch ON transaction_id_del_fact = ...`: si la
  transacción ya existe se actualiza (para capturar tardías o correcciones, ej.
  RETURNED que llega después), si no existe se inserta. Este patrón es idempotente: correr
  el mismo batch dos veces no duplica nada.
- Se mantiene una marca de agua (`high-water mark`) por tienda = última `transaction_date`
  procesada exitosamente, para saber desde dónde re-consultar en la siguiente corrida sin
  reprocesar todo el histórico.

### ¿Con qué frecuencia correría el pipeline?

- **Job de consolidación diaria** a las 2:30-3:00 AM: cierra el día anterior con datos
  completos, corre las transformaciones (dimensiones, fact, agregados) y refresca el
  dashboard para que el gerente regional lo tenga listo al llegar en la mañana.
- **Micro-batches horarios** en la capa staging (opcional, solo si el negocio pide
  visibilidad intradía) — no se propagan a la capa curada hasta el cierre nocturno.

---

## C. Gobernanza

### ¿Cómo proteger `customer_id`?

- **Pseudonimización**: en la capa curada, `customer_id` se reemplaza por un hash
  irreversible (SHA-256 + salt rotado periódicamente) antes de llegar a `dim_customer`. El
  valor original en texto plano solo vive en la capa raw, con acceso restringido.
- **Column-level security**: usando Policy Tags de BigQuery/Data Catalog, se marca la
  columna como PII y solo roles autorizados (ej. equipo de CRM) pueden verla sin hash;
  analistas de BI ven solo el hash o directamente el agregado, sin necesidad de ver el dato
  individual.
- **Minimización**: los análisis de cohortes/retención (Query 3) no requieren el
  `customer_id` real, solo un identificador consistente para agrupar — el hash cumple esa
  función sin exponer el dato original.
- **Retención**: definir política de borrado/anonimización para clientes inactivos según
  la normativa de protección de datos aplicable en cada país (CR, GT, HN, SV, NI).

### ¿Quién debería ser el data owner de la tabla de transacciones?

Se distingue **data owner** (accountable del negocio) de **data steward** (responsable
técnico del pipeline):
- **Data owner**: el área de **Operaciones de Tienda / VP Retail Operations**, porque son
  quienes generan el dato en el punto de venta y tienen autoridad para decidir reglas de
  negocio (ej. qué se considera una devolución válida, cómo se captura una promoción).
- **Data steward / técnico**: el equipo de **Data Engineering**, responsable de que el
  pipeline cargue correctamente, de la calidad técnica y de resolver incidentes de
  integración — pero no decide reglas de negocio, solo las implementa.

### Si dos reportes muestran GMV diferente para la misma tienda y el mismo día, ¿cuál es el proceso para resolverlo?

1. **Confirmar la definición usada en cada reporte**: ¿GMV bruto o neto de devoluciones?
   ¿usa `total_amount` de `transactions` o `SUM(unit_price*quantity)` de
   `transaction_items`? (Ya sabemos por el Bloque 0 que estas dos fuentes difieren en ~1% de
   los casos — es la sospecha #1.)
2. **Confirmar el filtro de fecha y zona horaria**: un reporte podría estar usando
   `transaction_date` en hora local de la tienda y otro en UTC, desplazando transacciones de
   medianoche a otro día.
3. **Confirmar el filtro de status**: ¿incluye `RETURNED` como negativo, lo excluye, o lo
   cuenta como venta bruta?
4. **Trazar ambos reportes hasta la fuente**: si uno consulta directo `transactions.csv`/
   tabla raw y otro consulta el `fact_sales` curado, el curado debe ganar por ser la fuente
   certificada — pero solo después de confirmar que el fact está bien construido.
5. **Documentar y corregir en el origen**: una vez identificada la causa, se corrige el
   reporte que se desvía del estándar (nunca se "ajustan" ambos hasta que coincidan sin
   entender por qué difieren), y se deja registrada la definición oficial de GMV en un
   diccionario de métricas para que no se repita.
6. **Prevención a futuro**: establecer una capa semántica única (ej. métricas certificadas
   en dbt o en el modelo de Power BI) para que todos los reportes usen la misma definición y
   fuente por diseño, no por disciplina manual.
