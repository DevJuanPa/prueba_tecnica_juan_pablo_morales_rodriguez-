# Bloque 4 — Framework de KPIs: Programa de Productividad de Tiendas

## Contexto y criterio de diseño

El equipo directivo quiere lanzar un programa de mejora de productividad de tiendas y no
existe framework previo. Este documento lo construye desde cero.

**Criterios que guiaron el diseño:**

1. **Targets basados en la data real, no en números redondos inventados.** Todos los targets
   se derivan de los percentiles observados en abril–junio 2025 (último trimestre completo
   del dataset). Un target de "$150 GMV/m²" sería absurdo para un HIPERMERCADO (mediana real:
   $73) y trivial para un EXPRESS (mediana real: $161).

2. **Comparación siempre dentro de formato, nunca entre formatos.** Un EXPRESS genera ~2.2x
   más GMV/m² que un HIPERMERCADO por diseño estructural (menos m², mayor rotación). Rankear
   entre formatos penalizaría injustamente a los hipermercados.

3. **Umbrales relativos, no absolutos, donde el absoluto no discrimina.** El GMROI de los
   **31 de 31 proveedores está por debajo de 1** (rango 0.37–0.95, mediana 0.61). Un umbral
   absoluto de "GMROI < 1" marcaría al 100% del catálogo. Por eso el KPI de proveedor usa el
   cuartil inferior *relativo*.

Cobertura: 8 KPIs sobre 3 dimensiones (productividad de tienda, experiencia del cliente,
desempeño de proveedor), incluyendo **1 leading indicator** (KPI 7) y **1 KPI compuesto**
(KPI 8).

---

## Tabla de KPIs

| # | KPI | Definición exacta | Fórmula | Frecuencia | Fuente de datos | Target sugerido | ¿Cómo detectas si el dato está mal? |
|---|---|---|---|---|---|---|---|
| 1 | **GMV por m²** *(productividad)* | Ingreso bruto generado por cada m² de sala de ventas en el período, para transacciones completadas. | `SUM(unit_price × quantity) [COMPLETED] / size_sqm` | Semanal (monitoreo) · Trimestral (evaluación) | `fact_sales_line` × `dim_store` | Superar el **p25 de su formato**. Benchmarks Q2-2025: HIPER $56, SUPER $67, DESCUENTO $86, EXPRESS $158. Meta anual: mover el p25 hacia la mediana. | `size_sqm` nulo/cero o fuera del rango del formato; GMV semanal a >3σ del promedio móvil de 8 semanas; tienda sin transacciones en día hábil (ver KPI 7). |
| 2 | **Ticket Promedio** *(productividad)* | Valor promedio en $ de una transacción completada. Se calcula desde líneas, no desde `total_amount`. | `SUM(unit_price × quantity) / COUNT(DISTINCT transaction_id)` | Semanal | `fact_sales_line` | Mantener o superar el mismo período del año anterior (base ~$279; por formato $277–$292). Objetivo: +3% YoY. | Diferencia >1% entre suma de líneas y `total_amount` (1,745 casos, 1.0% — chequeo de reconciliación permanente); líneas `unit_price=0` sin promo (231 casos) que deprimen el promedio; salto >20% semana contra semana sin cambio de mix. |
| 3 | **Transacciones por m²** *(productividad)* | Nº de transacciones completadas por m². Mide conversión del espacio, independiente del valor del ticket. | `COUNT(DISTINCT transaction_id) / size_sqm` | Semanal | `fact_sales_line` × `dim_store` | p50 de su formato. Se lee **junto** al KPI 2: si GMV/m² cae, distingue si es por menos tráfico o menor ticket. | `transaction_id` duplicado (0 actualmente); conteo de transacciones que no cuadra con conteo de líneas del día; transacciones antes de `opening_date` (50 en TIENDA_037). |
| 4 | **Tasa de Devolución** *(experiencia cliente)* | % de transacciones devueltas sobre el total del período. Proxy de insatisfacción y calidad de surtido. | `COUNT(id WHERE status='RETURNED') / COUNT(id) × 100` | Semanal | `fact_sales_line` × `dim_store` | Por debajo de **2.5%**. Base actual: 2.03% global, homogénea entre formatos (1.88–2.07%), países (1.93–2.16%) y categorías. Alerta si una tienda supera 3.5%. | Tasa 0.0% sostenida >2 semanas → no está registrando devoluciones, no es perfección; tasa >10% → error de captura de status; `RETURNED` sin líneas asociadas. |
| 5 | **Penetración de Lealtad** *(experiencia cliente)* | % de transacciones donde el cliente se identificó con tarjeta. Mide capacidad de convertir anónimos en clientes conocidos. | `COUNT(id WHERE loyalty_card=TRUE) / COUNT(id) × 100` | Semanal | `fact_sales_line` × `dim_customer` | Subir de **40.2%** actual a **50%** en 12 meses. Nota: el ticket con lealtad ($280) NO difiere del anónimo ($278; p=0.12), así que se justifica por *conocer* al cliente, no por mayor ticket. | `loyalty_card=TRUE` con `customer_id` nulo o viceversa (0 casos, chequeo activo); penetración 100% o 0% en una tienda → tarjeta escaneada por defecto o lector averiado. |
| 6 | **GMROI Relativo al Formato** *(proveedor)* | Retorno de margen bruto sobre inversión en costo de mercadería, por proveedor, como posición *relativa* al catálogo (no contra umbral fijo). | `GMROI = (SUM(gmv) − SUM(cost×qty)) / SUM(cost×qty)`, luego percentil del vendor en la distribución | Mensual | `fact_sales_line` × `dim_product` × `dim_vendor` | Ningún proveedor en el **cuartil inferior (p25)** por más de 2 trimestres sin renegociación. Rango real 0.37–0.95, mediana 0.61; los 31 de 31 bajo 1.0, por eso el umbral absoluto no sirve. | Productos con `vendor_id` inexistente (5: ITEM_045, 078, 112, 156, 189) → GMROI no atribuible; `cost > unit_price` sostenido → costo desactualizado; GMROI que cambia >50% mes contra mes sin cambio de precio/costo. |
| 7 | **Días de Quiebre Ponderados por Valor** *(proveedor · **LEADING**)* | Suma de días en que un SKU de alta rotación no vendió en una tienda donde históricamente sí vendía, ponderada por su GMV diario. Anticipa la caída de GMV antes del resultado del mes. | `SUM(días_sin_venta × unidades_prom_día × precio_prom)` restringido al **top 20% de SKUs por GMV** | Diaria (alerta) · Semanal (reporte) | `fact_sales_line` × `dim_product` × `dim_store` | Cero SKUs del top-20% con >3 días consecutivos sin venta. **Restricción crítica:** aplicado a todo el catálogo produce cifras sin sentido (309,786 "quiebres", pérdida 7x el GMV real) porque la mayoría de SKUs rota lento. Solo accionable en alta rotación. | Tienda entera "en quiebre" simultáneo → fallo de integración, no quiebre real (TIENDA_012, gap de 8 días); SKU con <5 días de historial marcado como quiebre → falso positivo por baja rotación. |
| 8 | **Índice de Salud de Tienda** *(**COMPUESTO**)* | Índice 0–100 que resume productividad + experiencia + ejecución. Cada componente se normaliza como percentil *dentro de su formato* antes de ponderar. | `0.40×pctl(GMV/m²) + 0.20×pctl(Ticket) + 0.15×pctl(Trans/m²) + 0.15×(100−pctl(Devolución)) + 0.10×pctl(Lealtad)` | Mensual | KPIs 1, 2, 3, 4 y 5 (compuesto por construcción) | Ninguna tienda por debajo de **40 pts**; promedio de la cadena a **60+**. Las tiendas bajo 40 entran al plan de intervención. | Si cualquier KPI componente tiene alerta activa, el índice se marca "no confiable" en vez de mostrar un número engañoso; salto >20 pts mes contra mes sin cambio operativo; tienda con <4 semanas de operación → no se calcula. |

---

## North Star Metric

### 🌟 GMV por m² comparable dentro de formato (Comp GMV/m²)

**Definición:** GMV por m² de tiendas con al menos 13 meses de operación, comparado contra el
mismo período del año anterior, medido dentro de cada formato.

### Por qué se eligió

**1. Es la métrica que el programa existe para mover.** El mandato es "mejorar productividad
de tiendas". Productividad = output por unidad de recurso, y en retail físico el recurso
escaso y costoso es el **m²** (renta, energía, personal, inventario). El GMV total crecería
solo abriendo tiendas nuevas sin que ninguna existente mejore — eso es expansión, no
productividad.

**2. Combina las tres dimensiones sin poder manipularse desde una sola.** GMV/m² sube solo si
mejora el tráfico convertido (KPI 3), el ticket (KPI 2), o ambos — y ambos dependen de que no
haya quiebres (KPI 7) y de que el surtido sea rentable (KPI 6). No se puede "hackear"
optimizando un componente.

**3. La comparabilidad evita falsas victorias.** Sin el filtro de tiendas maduras, el
crecimiento del GMV se confunde con el efecto de aperturas. La data lo confirma: la
correlación entre antigüedad y GMV/m² es **negativa (-0.22)**, y la tienda más nueva
(TIENDA_037, 12.9 meses) tiene el segundo GMV/m² más alto. Sin ajustar por madurez, se
premiaría a tiendas nuevas por ser nuevas.

**4. Se mide dentro de formato porque entre formatos no es comparable.** Un EXPRESS produce
~$161/m² y un HIPERMERCADO ~$73/m² — por modelo estructural, no por gestión. Compararlos en
crudo llevaría a "cerremos los hipermercados".

### Qué la desplazaría

Si el objetivo estratégico pasara de productividad de activos a **crecimiento de base de
clientes**, la North Star correcta sería el GMV de clientes retenidos identificados. Hoy no lo
es porque solo el 40.2% de las transacciones son identificables y el top 10% de clientes
explica apenas ~16% del GMV — no existe aún un núcleo de clientes leales suficiente para
colgar de él la métrica principal.
