# Bloque 5 — Parte A · Especificación del Dashboard Operativo (Power BI)

Documento de construcción del archivo `bloque5_dashboard.pbix`. Contiene el modelo de datos,
todas las medidas DAX y el layout de página.

**Principio de diseño:** el enunciado dice que si hay que explicarle al gerente regional cómo
usar el dashboard, el diseño falló. Por eso: una sola página principal, jerarquía visual clara
(KPIs arriba → tendencia al centro → detalle accionable abajo), semáforos en vez de tablas
densas, y cero jerga técnica en las etiquetas.

---

## 1. Modelo de datos (Power Query → modelo estrella)

Se replica el Star Schema del Bloque 2. Relaciones **uno a muchos**, dirección de filtro
**simple** (de dimensión a hechos).

| Tabla | Tipo | Clave | Notas de carga |
|---|---|---|---|
| `Fact_Sales` | Hechos | `transaction_item_id` | Merge de `transaction_items` + `transactions`. Grano: línea de ítem. |
| `Dim_Store` | Dimensión | `store_id` | Directo de `stores.csv` |
| `Dim_Product` | Dimensión | `item_id` | Directo de `products.csv` |
| `Dim_Vendor` | Dimensión | `vendor_id` | Directo de `vendors.csv` |
| `Dim_Date` | Dimensión | `Date` | **Generada en DAX** (ver abajo), marcada como tabla de fechas |
| `Dim_Customer` | Dimensión | `customer_key` | Con fila "Unknown" para el 60% sin identificar |

### Transformaciones en Power Query

```
// Fact_Sales — pasos clave
1. Merge transaction_items con transactions por transaction_id (Inner Join)
2. Columna calculada: line_gmv = unit_price * quantity
3. Filtrar: status = "COMPLETED" se maneja en DAX (no aquí), para poder
   reportar tasa de devolución sobre el total
4. EXCLUIR: transacciones de TIENDA_037 anteriores a 2024-06-01
   (hallazgo Bloque 0: 50 transacciones previas a opening_date)
5. Tipar transaction_date como Date
```

> **Decisión heredada del Bloque 0:** el GMV se calcula desde `unit_price × quantity`, nunca
> desde `total_amount`, por la discrepancia del 1% (1,745 transacciones) detectada en la
> auditoría. `total_amount` no se carga al modelo para evitar que alguien lo use por error.

### Tabla de fechas

```dax
Dim_Date =
ADDCOLUMNS(
    CALENDAR(DATE(2024,1,1), DATE(2025,6,30)),
    "Año", YEAR([Date]),
    "Mes", FORMAT([Date], "MMM"),
    "MesNum", MONTH([Date]),
    "AñoMes", FORMAT([Date], "YYYY-MM"),
    "Trimestre", "Q" & QUARTER([Date]),
    "Semana", WEEKNUM([Date], 2),
    "InicioSemana", [Date] - WEEKDAY([Date], 2) + 1,
    "DiaSemana", FORMAT([Date], "ddd")
)
```

---

## 2. Medidas DAX

### 2.1 Medidas base

```dax
GMV Neto =
CALCULATE(
    SUMX(Fact_Sales, Fact_Sales[unit_price] * Fact_Sales[quantity]),
    Fact_Sales[status] = "COMPLETED"
)

Transacciones =
CALCULATE(
    DISTINCTCOUNT(Fact_Sales[transaction_id]),
    Fact_Sales[status] = "COMPLETED"
)

Ticket Promedio = DIVIDE([GMV Neto], [Transacciones])

Metros Cuadrados = SUM(Dim_Store[size_sqm])

GMV por m2 = DIVIDE([GMV Neto], [Metros Cuadrados])

Transacciones por m2 = DIVIDE([Transacciones], [Metros Cuadrados])
```

### 2.2 Variación vs. semana anterior (requisito del header)

```dax
GMV Semana Anterior =
CALCULATE(
    [GMV Neto],
    DATEADD(Dim_Date[Date], -7, DAY)
)

GMV Var % Semanal =
VAR Actual = [GMV Neto]
VAR Anterior = [GMV Semana Anterior]
RETURN DIVIDE(Actual - Anterior, Anterior)

Ticket Semana Anterior =
CALCULATE([Ticket Promedio], DATEADD(Dim_Date[Date], -7, DAY))

Ticket Var % Semanal =
DIVIDE([Ticket Promedio] - [Ticket Semana Anterior], [Ticket Semana Anterior])

Transacciones Var % Semanal =
VAR Ant = CALCULATE([Transacciones], DATEADD(Dim_Date[Date], -7, DAY))
RETURN DIVIDE([Transacciones] - Ant, Ant)

GMV m2 Var % Semanal =
VAR Ant = CALCULATE([GMV por m2], DATEADD(Dim_Date[Date], -7, DAY))
RETURN DIVIDE([GMV por m2] - Ant, Ant)
```

### 2.3 Comp Sales (ventas comparables)

Solo tiendas con 13+ meses de operación, consistente con la Query 1 del Bloque 1.

```dax
-- Flag de tienda comparable
Es Tienda Comparable =
VAR FechaCorte = DATE(2024,5,30)
RETURN
IF(
    MAX(Dim_Store[opening_date]) <= FechaCorte
        && MAX(Dim_Store[store_id]) <> "TIENDA_037",
    1, 0
)

GMV Comparable =
CALCULATE(
    [GMV Neto],
    FILTER(
        ALL(Dim_Store),
        Dim_Store[opening_date] <= DATE(2024,5,30)
            && Dim_Store[store_id] <> "TIENDA_037"
    )
)

GMV Comparable Año Anterior =
CALCULATE([GMV Comparable], SAMEPERIODLASTYEAR(Dim_Date[Date]))

Comp Sales Growth % =
DIVIDE(
    [GMV Comparable] - [GMV Comparable Año Anterior],
    [GMV Comparable Año Anterior]
)
```

### 2.4 Alerta de bajo rendimiento (percentil 25 dentro de formato)

Esta es la medida más delicada del dashboard: el percentil debe calcularse **dentro del
formato**, porque un EXPRESS genera ~$161/m² y un HIPERMERCADO ~$73/m² por diseño
estructural. Compararlos en la misma escala marcaría en rojo a todos los hipermercados.

```dax
P25 GMV m2 del Formato =
VAR FormatoActual = SELECTEDVALUE(Dim_Store[format])
VAR TablaFormato =
    ADDCOLUMNS(
        FILTER(ALL(Dim_Store), Dim_Store[format] = FormatoActual),
        "@gmvm2",
        CALCULATE(
            DIVIDE([GMV Neto], SUM(Dim_Store[size_sqm]))
        )
    )
RETURN
    PERCENTILEX.INC(TablaFormato, [@gmvm2], 0.25)

Flag Bajo Rendimiento =
IF(
    [GMV por m2] < [P25 GMV m2 del Formato],
    "BAJO_RENDIMIENTO",
    "OK"
)

-- Medida para formato condicional (semáforo)
Color Rendimiento =
IF(
    [GMV por m2] < [P25 GMV m2 del Formato],
    "#C0392B",   -- rojo
    "#27AE60"    -- verde
)

Tiendas en Alerta =
SUMX(
    VALUES(Dim_Store[store_id]),
    IF([GMV por m2] < [P25 GMV m2 del Formato], 1, 0)
)
```

### 2.5 Ranking dentro de formato

```dax
Ranking en Formato =
IF(
    HASONEVALUE(Dim_Store[store_id]),
    RANKX(
        FILTER(
            ALL(Dim_Store),
            Dim_Store[format] = SELECTEDVALUE(Dim_Store[format])
        ),
        [GMV por m2],
        ,
        DESC,
        Dense
    )
)
```

### 2.6 Retención por cohorte

Requiere una columna calculada de cohorte en `Dim_Customer` y una tabla desconectada de
offsets.

```dax
-- Columna calculada en Dim_Customer
Cohorte =
VAR PrimeraCompra =
    CALCULATE(
        MIN(Fact_Sales[transaction_date]),
        ALLEXCEPT(Dim_Customer, Dim_Customer[customer_key])
    )
RETURN FORMAT(PrimeraCompra, "YYYY-MM")

-- Tabla desconectada para el eje de columnas
Offsets = DATATABLE("Mes Offset", INTEGER, {{0},{1},{2},{3},{6}})

Clientes en Cohorte =
CALCULATE(
    DISTINCTCOUNT(Fact_Sales[customer_id]),
    Fact_Sales[loyalty_card] = TRUE()
)

Clientes Retenidos =
VAR Offset = SELECTEDVALUE(Offsets[Mes Offset])
VAR CohorteSel = SELECTEDVALUE(Dim_Customer[Cohorte])
VAR MesObjetivo = EDATE(DATEVALUE(CohorteSel & "-01"), Offset)
RETURN
CALCULATE(
    DISTINCTCOUNT(Fact_Sales[customer_id]),
    Fact_Sales[loyalty_card] = TRUE(),
    FILTER(
        ALL(Dim_Date),
        EOMONTH(Dim_Date[Date],0) = EOMONTH(MesObjetivo,0)
    )
)

Retencion % =
DIVIDE(
    [Clientes Retenidos],
    CALCULATE([Clientes en Cohorte], Offsets[Mes Offset] = 0)
)
```

### 2.7 Quiebres de stock activos

```dax
Dias Sin Venta =
VAR UltimaVenta =
    CALCULATE(
        MAX(Fact_Sales[transaction_date]),
        ALLEXCEPT(Fact_Sales, Dim_Store[store_id], Dim_Product[item_id])
    )
VAR FechaMax = MAX(Dim_Date[Date])
RETURN DATEDIFF(UltimaVenta, FechaMax, DAY)

Quiebre Activo =
IF([Dias Sin Venta] >= 3, "SI", "NO")
```

> **Restricción metodológica obligatoria en el visual:** este listado debe filtrarse al
> **top 20% de SKUs por GMV** (40 de 200 productos, que concentran el 69.5% de las ventas).
> Aplicado a todo el catálogo, el indicador pierde todo significado: el análisis del Bloque 3
> mostró que la definición literal genera más de 300,000 "quiebres" y una pérdida estimada que
> supera 7 veces el GMV real, porque la mayoría de SKUs simplemente rota lento. El visual
> debe llevar la leyenda: *"Solo SKUs de alta rotación. Requiere validación con inventario."*

### 2.8 Tasa de devolución

```dax
Tasa Devolucion % =
DIVIDE(
    CALCULATE(DISTINCTCOUNT(Fact_Sales[transaction_id]), Fact_Sales[status] = "RETURNED"),
    DISTINCTCOUNT(Fact_Sales[transaction_id])
)
```

---

## 3. Layout de la página principal

```
┌──────────────────────────────────────────────────────────────────────┐
│  FILTROS (barra superior):  País ▾   Formato ▾   Región ▾   Fechas ▾ │
├──────────────────────────────────────────────────────────────────────┤
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐              │
│  │ GMV NETO │  │  TRANS.  │  │  TICKET  │  │  GMV/m²  │   ← 4 cards  │
│  │  $15.5M  │  │  174.9K  │  │   $279   │  │   $95    │              │
│  │  ▲ +6.5% │  │  ▲ +2.1% │  │  ▼ -0.3% │  │  ▲ +4.2% │   vs sem.ant.│
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘              │
├───────────────────────────────────┬──────────────────────────────────┤
│  COMP SALES: tendencia semanal    │  RANKING DE TIENDAS               │
│  año actual vs. anterior          │  (dentro de su formato)           │
│  [gráfico de líneas por formato]  │  [barras horizontales +           │
│                                   │   semáforo rojo si < p25]         │
├───────────────────────────────────┼──────────────────────────────────┤
│  RETENCIÓN POR COHORTE            │  QUIEBRES ACTIVOS                 │
│  [matriz heatmap: cohorte × mes]  │  [tabla: tienda, ítem, días]      │
│                                   │   solo SKUs alta rotación         │
└───────────────────────────────────┴──────────────────────────────────┘
```

### Configuración por visual

| Visual | Tipo | Campos / medidas | Formato condicional |
|---|---|---|---|
| Header (4 cards) | Card / KPI | `GMV Neto`, `Transacciones`, `Ticket Promedio`, `GMV por m2` + sus `Var % Semanal` | Flecha verde si var > 0, roja si < 0 |
| Comp Sales | Gráfico de líneas | Eje: `Dim_Date[InicioSemana]` · Valores: `GMV Comparable`, `GMV Comparable Año Anterior` · Leyenda: `Dim_Store[format]` | — |
| Ranking tiendas | Barras horizontales | Eje: `Dim_Store[store_name]` · Valor: `GMV por m2` | Color por `Color Rendimiento` (rojo si < p25) |
| Retención | Matriz | Filas: `Dim_Customer[Cohorte]` · Columnas: `Offsets[Mes Offset]` · Valor: `Retencion %` | Escala de color YlGnBu |
| Quiebres | Tabla | `store_name`, `item_name`, `category`, `Dias Sin Venta` | Fondo rojo si días > 14. **Filtro obligatorio: top 20% SKUs** |
| Filtros | Segmentaciones | `country`, `format`, `region`, `Dim_Date[Date]` | Sincronizadas entre páginas |

### Notas de usabilidad

- **Ordenamiento por defecto:** ranking de tiendas de peor a mejor — el gerente necesita ver
  primero dónde actuar, no felicitarse por las mejores.
- **Tooltips:** al pasar sobre una tienda en el ranking, mostrar formato, m², ticket y
  ranking dentro de formato.
- **Sin scroll horizontal** y máximo 6 visuales en la página principal: si no cabe en una
  pantalla, no lo va a mirar a diario.
- **Etiquetas en lenguaje de negocio:** "Ventas por metro cuadrado", no "GMV/m² (measure)".

---

## 4. Advertencias que el dashboard debe mostrar en pantalla

Un dashboard que oculta problemas de calidad de datos es peor que no tener dashboard. Se
incluye un ícono de información con estas notas activas:

1. **1,745 transacciones (1.0%)** tienen diferencia entre el monto reportado y la suma de sus
   líneas. El dashboard usa la suma de líneas.
2. **TIENDA_012** presentó un gap de 8 días consecutivos sin ventas — validar si fue cierre
   real o fallo de integración antes de evaluar su desempeño.
3. **El indicador de quiebres no está validado contra inventario.** Mide ausencia de venta, no
   ausencia de stock. Es una señal de investigación, no una medición de pérdida.
