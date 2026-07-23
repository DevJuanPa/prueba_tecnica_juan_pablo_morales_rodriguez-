# Prueba Técnica · Data Analyst — Cadena de Retail Multiformato (Centroamérica)

Análisis de 18 meses de operación (enero 2024 – junio 2025) de una cadena de retail con
40 tiendas, 4 formatos y presencia en 5 países.

**Volumen procesado:** 174,880 transacciones · 542,015 líneas de detalle · 200 SKUs · 31 proveedores

---

## Estructura del repositorio

```
prueba_tecnica_juan_pablo_morales/
├── README.md                       ← este archivo
├── requirements.txt                 Dependencias de Python
├── data/                            CSVs originales (6 archivos)
├── bloque0_auditoria.md             Auditoría de calidad de datos
├── bloque1_queries.sql              6 queries en BigQuery SQL, comentadas
├── bloque2_modelo.pdf               Diagrama del Star Schema
├── bloque2_decisiones.md            Decisiones de diseño + ETL + gobernanza
├── bloque3_analisis.ipynb           Notebook: EDA + A/B test
├── bloque3_analisis.html            Versión HTML ejecutada (sin necesidad de correr)
├── bloque3_visualizaciones/         7 gráficos exportados (PNG)
├── bloque4_kpi_framework.md         Framework de 8 KPIs + North Star Metric
├── bloque5_dashboard.pbix           Dashboard operativo en Power BI
├── bloque5_dashboard_spec.md        Modelo de datos + medidas DAX documentadas
└── bloque5_presentacion_EN.pdf      Presentación ejecutiva (5 slides, inglés)
```

---

## Cómo correr el código

### Requisitos

- Python 3.10 o superior
- Power BI Desktop (solo para abrir el `.pbix`)

### Instalación

```bash
git clone https://github.com/DevJuanPa/prueba_tecnica_juan_pablo_morales_rodriguez-
cd prueba_tecnica_juan_pablo_morales
pip install -r requirements.txt
```

`requirements.txt`:
```
pandas>=2.0
numpy>=1.24
scipy>=1.10
matplotlib>=3.7
seaborn>=0.12
jupyter>=1.0
```

### Ejecutar el análisis (Bloque 3)

```bash
jupyter notebook bloque3_analisis.ipynb
```

Ejecutar todas las celdas en orden (`Cell → Run All`). El notebook lee los CSVs desde la
carpeta `data/` y regenera las 7 visualizaciones en `bloque3_visualizaciones/`.

> Si solo se quiere revisar el resultado sin ejecutar nada, abrir `bloque3_analisis.html`
> en cualquier navegador — contiene el notebook ya ejecutado con todas sus salidas.

**Tiempo aproximado de ejecución:** 3–5 minutos. La celda más pesada es la detección de
quiebres de stock (Pregunta 4), que agrega 542K líneas a nivel tienda–SKU–día. Está
vectorizada con `rolling('14D')` de pandas en lugar de un bucle, lo que reduce el tiempo
de varios minutos a unos pocos segundos.

### Ejecutar las queries (Bloque 1)

Las queries de `bloque1_queries.sql` están escritas en **BigQuery Standard SQL** y asumen
un dataset llamado `retail` con las 6 tablas cargadas:

```sql
-- Ejemplo de carga desde CSV a BigQuery
bq load --autodetect --source_format=CSV retail.transactions data/transactions.csv
```

Cada query está comentada e indica en su encabezado qué decisión del Bloque 0 aplica.

---

## Decisiones transversales del análisis

Estas decisiones se tomaron en la auditoría (Bloque 0) y se aplican de forma consistente en
**todos** los bloques posteriores:

| Decisión | Motivo |
|---|---|
| GMV se calcula desde `unit_price × quantity` de `transaction_items` | 1,745 transacciones (1.0%) tienen `total_amount` que no coincide con la suma de sus líneas |
| Se excluyen 50 transacciones de TIENDA_037 previas a su `opening_date` | Distorsionan el cálculo de Comp Sales y antigüedad de tienda |
| Se excluyen TIENDA_008 y TIENDA_037 del A/B test | Ambas aparecen asignadas simultáneamente a CONTROL y TREATMENT |
| Se excluyen 5 productos con `vendor_id` huérfano del GMROI por proveedor | No existen en el catálogo de proveedores |
| Solo `status = COMPLETED` cuenta para GMV bruto | Las devoluciones se reportan aparte como tasa de devolución |

---

## Hallazgos principales

**1. El resultado del A/B test se invierte al corregir el diseño experimental.**
La comparación directa de TREATMENT vs. CONTROL da −16.99% (p=0.018), lo que llevaría a
descartar la nueva exhibición. Pero los grupos no estaban balanceados: las tiendas CONTROL
eran 71% más grandes (3,100 m² vs. 1,813 m²) y su GMV pre-test ya era 35% mayor. Aplicando
diferencia-en-diferencias, el efecto real es **+10.2 puntos porcentuales a favor de
TREATMENT (p=0.014)**.

**2. La métrica de quiebres de stock no es medible con los datos disponibles.**
La definición literal del enunciado (3+ días sin venta) produce 309,786 "quiebres" y un GMV
perdido estimado de $339M contra un GMV real de $47.8M — **7 veces el total de ventas del
período**. La causa es estructural: con 200 SKUs en 40 tiendas, cada par tienda–SKU vende
solo ~20% de los días. Sin datos de inventario no se puede distinguir "no había stock" de
"no rota tan seguido". Se documenta como brecha de datos, no como pérdida cuantificada.

**3. El umbral de GMROI < 1 no discrimina nada en este catálogo.**
Los **31 de 31 proveedores** están por debajo de 1.0 (rango 0.37–0.95, mediana 0.61). Usar
ese flag marcaría el 100% del catálogo. En el framework de KPIs se reemplazó por un umbral
relativo (cuartil inferior de la distribución).

**4. Las categorías están concentradas; los clientes no.**
3 de 8 categorías concentran el 84% del GMV, pero el top 10% de clientes explica solo ~16%
de las ventas identificadas (en retail típico sería 30–40%). No existe un segmento VIP
sobre el cual construir retención focalizada.

**5. Los clientes de lealtad no gastan más.**
Ticket promedio de $280.38 con tarjeta vs. $277.80 sin tarjeta — diferencia no significativa
(p=0.12). El programa se justifica por capacidad de segmentación y medición, no por un
ticket mayor.

---

## Uso de herramientas de IA

Usé **Claude (Anthropic)** como asistente durante toda la prueba. A continuación documento
cómo lo usé, qué generó, qué modifiqué y qué validé por mi cuenta.

### Cómo estructuré el trabajo con la IA

Trabajé **bloque por bloque**, no pidiendo "resolveme la prueba completa". Cada bloque
arrancó cargando los CSVs reales y ejecutando código sobre ellos, no pidiendo respuestas
teóricas. Esto fue deliberado: quería que cada afirmación del entregable estuviera
respaldada por un número calculado sobre los datos, no por una suposición del modelo.

### Prompts principales que usé

| Bloque | Prompt (resumido) | Qué generó la IA |
|---|---|---|
| Inicial | *"Tengo esta prueba y datasets para una entrevista. Ayudame a pensar una solución"* | Plan de ataque por bloque, recomendación de stack según el peso de evaluación de cada bloque |
| 0 | *"Empecemos por el Bloque 0 (auditoría)"* | Script de pandas cubriendo las 8 dimensiones + documento con evidencia y decisiones |
| — | *"¿Consideras que yo deba realizarlo en Python?"* | Análisis de qué bloques convenía resolver en SQL vs. Python y por qué |
| 1 | Queries del Bloque 1 en BigQuery SQL | 6 queries comentadas + validación cruzada con pandas |
| 2 | Modelado + pipeline | Diagrama del Star Schema (graphviz) + documento de decisiones |
| 3 | EDA + A/B test | Notebook completo con 7 visualizaciones y pruebas estadísticas |
| 4 | Framework de KPIs | 8 KPIs con targets calculados desde percentiles reales del dataset |
| 5 | *"Para el bloque 5 prefiero Power BI"* | Medidas DAX + especificación del dashboard + presentación en inglés |

### Qué modifiqué o redirigí yo

- **Elegí Power BI para el Bloque 5** en lugar de otras herramientas propuestas, por ser la
  herramienta con la que tengo experiencia real construyendo modelos con DAX y RLS.
- **Decidí mantener el Bloque 1 en SQL** en lugar de resolverlo en pandas, después de
  discutir el trade-off: el entregable pedido es un `.sql` y la rúbrica evalúa uso de
  funciones avanzadas de SQL, no capacidad de agregar en Python.
- **Definí el orden de trabajo** (bloque por bloque en vez de en paralelo) para que las
  decisiones de la auditoría se propagaran de forma consistente a los bloques siguientes.

### Dónde la IA se equivocó o hubo que corregir el rumbo

Documento esto porque considero que es la parte más relevante de evaluar el criterio de uso:

- **Primera versión de la detección de quiebres:** el script inicial usaba un bucle sobre
  cada par tienda–SKU y excedió el tiempo de ejecución. Hubo que reescribirlo vectorizado
  con `rolling('14D')`.
- **El resultado del A/B test estuvo a punto de reportarse mal.** El primer cálculo dio
  −16.99% y ese habría sido el resultado entregado. Solo al revisar el balance pre-test se
  detectó que los grupos no eran comparables, lo que obligó a aplicar
  diferencia-en-diferencias y cambió la conclusión por completo.
- **La cifra de GMV perdido por quiebres es matemáticamente correcta pero conceptualmente
  inservible.** Aplicar la fórmula al pie de la letra da $339M. Decidí reportar la
  limitación en lugar del número, incluso sabiendo que un número grande "luce" mejor en una
  presentación ejecutiva.

### Qué validé manualmente

> **Nota:** esta sección debe reflejar únicamente lo que verifiqué de forma efectiva.

- Ejecuté el notebook completo de principio a fin y confirmé que corre sin errores.
- Contrasté los resultados de la Query 1 (Comp Sales) calculando lo mismo con pandas sobre
  los CSVs, y confirmé que el número de tiendas elegibles y los crecimientos por país y
  formato coinciden.
- Verifiqué los totales de la auditoría contra conteos directos sobre los CSVs
  (nulos, duplicados, huérfanos, transacciones previas a apertura).
- Revisé que las decisiones del Bloque 0 estuvieran efectivamente aplicadas en los bloques
  siguientes y no solo declaradas.

### Mi criterio sobre el uso de IA en este ejercicio

La IA aceleró de forma significativa la parte mecánica: escribir código de agregación,
generar visualizaciones, redactar en inglés. Donde no reemplazó el criterio propio fue en
decidir **qué números merecen ser reportados**. El caso del A/B test es el mejor ejemplo:
el cálculo estaba bien hecho desde el inicio, pero un cálculo correcto sobre un experimento
mal diseñado produce una conclusión equivocada. Detectar eso requiere preguntarse si el
resultado tiene sentido antes de aceptarlo — y esa validación es responsabilidad de quien
firma el análisis, no de la herramienta.

---

## Limitaciones conocidas

- **No hay datos de inventario**, por lo que los quiebres de stock son inferidos desde
  ausencia de ventas y no pueden validarse.
- **El dataset cubre 18 meses**, por lo que el Comp Sales YoY solo puede compararse sobre el
  semestre enero–junio.
- **Las cohortes de lealtad están desbalanceadas**: 2,046 de ~3,000 clientes pertenecen a la
  cohorte de enero 2024, y las cohortes de julio–agosto tienen 1–2 clientes, por lo que sus
  tasas de retención no son estadísticamente confiables.
- **El experimento A/B tiene un solo tratamiento** (`Exhibicion_Q3_2024`) y N reducido
  (38 tiendas válidas tras excluir las 2 contaminadas).

---

**Autor:** Juan Pablo Morales Rodríguez
**Contacto:** [correo] · [LinkedIn]
