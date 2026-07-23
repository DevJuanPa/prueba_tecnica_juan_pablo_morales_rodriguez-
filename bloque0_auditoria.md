# Bloque 0 — Auditoría de Calidad de Datos

Auditoría realizada con Python/pandas sobre los 6 datasets crudos, antes de cualquier
transformación o análisis. Dataset: 174,880 transacciones · 542,015 líneas de detalle ·
40 tiendas · 200 productos · 31 proveedores · 546 días (2024-01-01 a 2025-06-30).

---

## 1. Completitud

**Pregunta:** ¿Qué % de transacciones no tiene `customer_id`? ¿Es consistente con `loyalty_card = FALSE`?

| Métrica | Valor |
|---|---|
| Transacciones sin `customer_id` | 104,632 (59.83%) |
| Transacciones con `loyalty_card = FALSE` | 104,632 (59.83%) |
| Casos `customer_id` nulo pero `loyalty_card = TRUE` | 0 |
| Casos `customer_id` presente pero `loyalty_card = FALSE` | 0 |

**Hallazgo:** la relación es 100% consistente — no es un problema de calidad, es el diseño
esperado del negocio (clientes sin tarjeta de lealtad no se identifican).

**Decisión:** no requiere corrección. Para análisis de cohortes/retención se trabajará
únicamente con el ~40% de transacciones identificadas (`loyalty_card = TRUE`), documentando
explícitamente que las conclusiones de lealtad no son representativas del 100% de las ventas.

---

## 2. Consistencia

**Pregunta:** ¿`total_amount` coincide con `SUM(unit_price × quantity)` de `transaction_items`?

| Métrica | Valor |
|---|---|
| Transacciones con diferencia > $0.01 | 1,745 (1.00%) |
| Diferencia absoluta promedio | ~$18.40 |
| De esas, status COMPLETED | 1,717 |
| De esas, status RETURNED | 28 |

**Hallazgo:** en general `total_amount` es más bajo que la suma de líneas — consistente con
descuentos/promos a nivel de transacción no reflejados en `unit_price`, o con errores de
captura. El hecho de que 1,717 sean COMPLETED (no devoluciones) descarta que sea solo un
efecto de `status = RETURNED`.

**Decisión:** para cálculos de GMV usar `SUM(unit_price × quantity)` de `transaction_items`
como fuente de verdad (grano más fino y auditable), no `total_amount` de `transactions`.
Se documenta el 1% de discrepancia como alerta para el equipo de POS/data source.

---

## 3. Unicidad

**Pregunta:** ¿Existen `transaction_id` duplicados?

| Métrica | Valor |
|---|---|
| `transaction_id` duplicados en `transactions` | 0 |
| `transaction_item_id` duplicados en `transaction_items` | 0 |

**Hallazgo:** ambas llaves primarias son únicas.

**Decisión:** ninguna acción requerida.

---

## 4. Validez

**Pregunta:** ¿Hay `total_amount` negativos o cero? ¿`unit_price = 0` con `was_on_promo = FALSE`?

| Métrica | Valor |
|---|---|
| `total_amount ≤ 0` | 3 transacciones, todas COMPLETED |
| `unit_price = 0` con `was_on_promo = FALSE` | 231 líneas |
| `unit_price = 0` con `was_on_promo = TRUE` | 0 líneas |

**Hallazgo:** las 3 transacciones con monto ≤0 no son devoluciones (serían esperables ahí,
no en COMPLETED), por lo que probablemente son error de captura. Las 231 líneas de precio 0
sin promo son sospechosas — un precio 0 sin promoción activa no tiene sentido de negocio
(nótese que precio 0 *con* promo = 0 casos, lo que refuerza que "precio 0" debería estar
siempre ligado a `was_on_promo = TRUE`, ej. regalos/bundles).

**Decisión:** excluir las 3 transacciones de `total_amount ≤ 0` de cálculos de GMV y
marcarlas para revisión manual. Las 231 líneas de `unit_price = 0` sin promo se excluyen del
cálculo de ticket promedio y GMROI (distorsionan el promedio), pero se cuentan en unidades
vendidas; se marcan como alerta de calidad de captura en POS.

---

## 5. Integridad referencial

**Pregunta:** ¿`store_id` en `transactions` sin match en `stores`? ¿`vendor_id` en `products`
sin match en `vendors`?

| Métrica | Valor |
|---|---|
| `store_id` huérfano en `transactions` | 0 |
| `vendor_id` huérfano en `products` | 5 (ITEM_045, ITEM_078, ITEM_112, ITEM_156, ITEM_189) |
| `item_id` huérfano en `transaction_items` | 0 |
| `transaction_id` huérfano en `transaction_items` | 0 |

**Hallazgo:** las llaves de tienda y transacción están 100% íntegras. 5 productos
referencian un `vendor_id` que no existe en el catálogo de proveedores — probablemente
proveedores dados de baja o error de carga en `vendors.csv`.

**Decisión:** para el análisis de GMROI por vendor (Query 4, Bloque 1), estos 5 productos se
excluyen del agrupamiento por vendor (no se puede calcular GMROI sin `tier`/país del
proveedor) pero se conservan en el GMV total. Se documenta como alerta de integridad de
catálogo maestro.

---

## 6. Frescura

**Pregunta:** ¿Hay tiendas con gaps de días consecutivos sin transacciones? ¿Son esperables o
sospechosos?

| Métrica | Valor |
|---|---|
| Gap máximo típico por tienda | 1-2 días |
| Tiendas con gap > 7 días | 1 (TIENDA_012, gap de 8 días) |

**Hallazgo:** el patrón normal es de 1-2 días sin ventas (probablemente días de muy bajo
tráfico o cierre parcial), esperable en un dataset sintético con ruido. TIENDA_012 con 8 días
consecutivos sin ninguna venta es un outlier — podría indicar cierre temporal, problema de
integración de POS, o simplemente ruido sintético.

**Decisión:** se marca TIENDA_012 con alerta de "posible interrupción de reporte" para
revisión operativa; no se excluye del análisis pero se anota en el dashboard (Bloque 5) como
caso a validar con la tienda.

---

## 7. Integridad temporal

**Pregunta:** ¿Existe alguna tienda con transacciones anteriores a su `opening_date`?

| Métrica | Valor |
|---|---|
| Transacciones antes de `opening_date` | 50 |
| Tiendas afectadas | 1 (TIENDA_037) |
| Anticipación (min–max) | 1 a 17 días antes de apertura |

**Hallazgo:** TIENDA_037 registra 50 transacciones entre el 2024-05-15 y su apertura oficial
el 2024-06-01. Podría ser una "soft opening" no reflejada en `opening_date`, o un error en la
fecha de apertura del maestro de tiendas.

**Decisión:** excluir estas 50 transacciones de los cálculos de Comp Sales y antigüedad de
tienda (Query 1, Bloque 1), ya que distorsionarían la comparación YoY. Se documenta como
hallazgo para corregir `opening_date` en el maestro de tiendas.

---

## 8. A/B Test

**Pregunta:** ¿Hay tiendas asignadas simultáneamente a CONTROL y TREATMENT?

| Métrica | Valor |
|---|---|
| Experimento activo | `Exhibicion_Q3_2024` (único experimento en el dataset) |
| Tiendas con doble asignación | 2 (TIENDA_008, TIENDA_037) |
| Fechas | ambas asignaciones cubren el mismo rango: 2024-09-01 a 2024-10-12 |

**Hallazgo:** TIENDA_008 y TIENDA_037 aparecen simultáneamente como CONTROL y TREATMENT para
el mismo experimento y mismo rango de fechas — esto es un error de diseño/carga del
experimento, no es posible que una tienda reciba ambos tratamientos a la vez.

**Decisión:** excluir TIENDA_008 y TIENDA_037 del análisis del A/B test (Bloque 3, Parte B)
por contaminación del grupo de asignación. Se documenta explícitamente en la sección de
validación del experimento como una limitación que reduce el N de tiendas válidas de 40 a 38
(o al subconjunto que participa en el experimento, menos estas 2).

Nota: TIENDA_037 también fue la tienda con problema de integridad temporal (hallazgo #7),
lo que sugiere que sus datos maestros en general requieren revisión prioritaria.

---

## Resumen ejecutivo de decisiones para bloques siguientes

| # | Hallazgo | Filas afectadas | Decisión |
|---|---|---|---|
| 1 | customer_id nulo | 104,632 (59.8%) | Conservar — es diseño esperado, no error |
| 2 | total_amount ≠ suma de líneas | 1,745 (1.0%) | Usar `transaction_items` como fuente de verdad para GMV |
| 3 | Duplicados | 0 | N/A |
| 4a | total_amount ≤ 0 | 3 | Excluir de GMV, marcar para revisión |
| 4b | unit_price=0 sin promo | 231 | Excluir de ticket promedio/GMROI, mantener en unidades |
| 5 | vendor_id huérfano | 5 productos | Excluir de GMROI por vendor |
| 6 | Gap 8 días TIENDA_012 | — | Alerta operativa, no excluir |
| 7 | Ventas antes de apertura | 50 (TIENDA_037) | Excluir de Comp Sales / antigüedad de tienda |
| 8 | Doble asignación A/B | 2 tiendas (TIENDA_008, TIENDA_037) | Excluir del A/B test |
