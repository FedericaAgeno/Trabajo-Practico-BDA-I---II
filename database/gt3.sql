-- =====================================================================
-- TP Base de Datos Aplicada - Concesionaria GT3
-- Motor: SQL Server
-- Ejecutar completo en SSMS / Azure Data Studio (crea la base desde cero)
-- =====================================================================
USE master;   -- salir de GT3 para poder borrarla
GO

IF DB_ID('GT3') IS NOT NULL
BEGIN
    ALTER DATABASE GT3 SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE GT3;
END
GO

CREATE DATABASE GT3;
GO

USE GT3;
GO

-- ---------------------------------------------------------------------
-- 1. Usuarios (login)
-- ---------------------------------------------------------------------
CREATE TABLE usuario (
    id_usuario     INT IDENTITY(1,1) CONSTRAINT PK_usuario PRIMARY KEY,
    login          VARCHAR(50)   NOT NULL CONSTRAINT UQ_usuario_login UNIQUE,
    password_hash  VARCHAR(255)  NOT NULL,   -- nunca guardar la contraseña en texto plano
    activo         BIT           NOT NULL CONSTRAINT DF_usuario_activo DEFAULT 1,
    creado_en      DATETIME2(0)  NOT NULL CONSTRAINT DF_usuario_creado DEFAULT SYSDATETIME()
);
GO

-- ---------------------------------------------------------------------
-- 2. Ubicación (filtros Provincia / Localidad)
-- ---------------------------------------------------------------------
CREATE TABLE provincia (
    id_provincia   INT IDENTITY(1,1) CONSTRAINT PK_provincia PRIMARY KEY,
    nombre         NVARCHAR(80) NOT NULL CONSTRAINT UQ_provincia_nombre UNIQUE
);

CREATE TABLE localidad (
    id_localidad   INT IDENTITY(1,1) CONSTRAINT PK_localidad PRIMARY KEY,
    id_provincia   INT          NOT NULL
                   CONSTRAINT FK_localidad_provincia REFERENCES provincia(id_provincia),
    nombre         NVARCHAR(80) NOT NULL,
    CONSTRAINT UQ_localidad UNIQUE (id_provincia, nombre)
);
GO

-- ---------------------------------------------------------------------
-- 3. Catálogo de vehículos
-- ---------------------------------------------------------------------
CREATE TABLE tipo_motor (
    id_tipo_motor  INT IDENTITY(1,1) CONSTRAINT PK_tipo_motor PRIMARY KEY,
    descripcion    NVARCHAR(80) NOT NULL CONSTRAINT UQ_tipo_motor UNIQUE   -- ej: 4.0L Bóxer 6 cilindros
);

CREATE TABLE modelo (
    id_modelo      INT IDENTITY(1,1) CONSTRAINT PK_modelo PRIMARY KEY,
    nombre         NVARCHAR(100) NOT NULL CONSTRAINT UQ_modelo_nombre UNIQUE,  -- "Nombre" del tablero
    id_tipo_motor  INT           NOT NULL
                   CONSTRAINT FK_modelo_tipo_motor REFERENCES tipo_motor(id_tipo_motor)
);
GO

-- ---------------------------------------------------------------------
-- 4. Sucursales (donde se guarda el stock) y su stock mínimo de alerta
-- ---------------------------------------------------------------------
CREATE TABLE sucursal (
    id_sucursal    INT IDENTITY(1,1) CONSTRAINT PK_sucursal PRIMARY KEY,
    nombre         NVARCHAR(100) NOT NULL CONSTRAINT UQ_sucursal_nombre UNIQUE,
    id_localidad   INT           NOT NULL
                   CONSTRAINT FK_sucursal_localidad REFERENCES localidad(id_localidad),
    stock_minimo   INT           NOT NULL CONSTRAINT DF_sucursal_stock_minimo DEFAULT 1
                   CONSTRAINT CK_sucursal_stock_minimo CHECK (stock_minimo >= 0)
                   -- "Mínimo stock para la alerta"
);
GO

-- ---------------------------------------------------------------------
-- 5. Vehículos físicos (cada uno con su chasis)
-- ---------------------------------------------------------------------
CREATE TABLE vehiculo (
    id_vehiculo    INT IDENTITY(1,1) CONSTRAINT PK_vehiculo PRIMARY KEY,
    chasis         VARCHAR(17)  NOT NULL CONSTRAINT UQ_vehiculo_chasis UNIQUE,   -- VIN: 17 caracteres
    id_modelo      INT          NOT NULL
                   CONSTRAINT FK_vehiculo_modelo REFERENCES modelo(id_modelo),
    id_sucursal    INT          NOT NULL
                   CONSTRAINT FK_vehiculo_sucursal REFERENCES sucursal(id_sucursal),
    estado         VARCHAR(10)  NOT NULL CONSTRAINT DF_vehiculo_estado DEFAULT 'EN_STOCK'
                   CONSTRAINT CK_vehiculo_estado CHECK (estado IN ('EN_STOCK', 'VENDIDO')),
    fecha_ingreso  DATE         NOT NULL CONSTRAINT DF_vehiculo_ingreso DEFAULT CAST(SYSDATETIME() AS DATE),
    fecha_egreso   DATE         NULL,
    CONSTRAINT CK_vehiculo_fechas CHECK (fecha_egreso IS NULL OR fecha_egreso >= fecha_ingreso),
    CONSTRAINT CK_vehiculo_estado_egreso CHECK (
        (estado = 'VENDIDO'  AND fecha_egreso IS NOT NULL) OR
        (estado = 'EN_STOCK' AND fecha_egreso IS NULL)
    )
);

CREATE INDEX ix_vehiculo_sucursal_estado ON vehiculo (id_sucursal, estado);
CREATE INDEX ix_vehiculo_modelo          ON vehiculo (id_modelo);
CREATE INDEX ix_localidad_provincia      ON localidad (id_provincia);
CREATE INDEX ix_sucursal_localidad       ON sucursal (id_localidad);
GO

-- ---------------------------------------------------------------------
-- 6. Clientes y Ventas  (NUEVO)
-- ---------------------------------------------------------------------
CREATE TABLE cliente (
    id_cliente     INT IDENTITY(1,1) CONSTRAINT PK_cliente PRIMARY KEY,
    nombre         NVARCHAR(60)  NOT NULL,
    apellido       NVARCHAR(60)  NOT NULL,
    dni            VARCHAR(10)   NOT NULL CONSTRAINT UQ_cliente_dni UNIQUE,
    email          VARCHAR(120)  NULL,
    id_localidad   INT           NOT NULL
                   CONSTRAINT FK_cliente_localidad REFERENCES localidad(id_localidad)
);

CREATE TABLE venta (
    id_venta       INT IDENTITY(1,1) CONSTRAINT PK_venta PRIMARY KEY,
    id_vehiculo    INT           NOT NULL
                   CONSTRAINT FK_venta_vehiculo REFERENCES vehiculo(id_vehiculo)
                   CONSTRAINT UQ_venta_vehiculo UNIQUE,      -- un vehículo se vende una sola vez
    id_cliente     INT           NOT NULL
                   CONSTRAINT FK_venta_cliente REFERENCES cliente(id_cliente),
    fecha_venta    DATE          NOT NULL,
    precio_usd     DECIMAL(12,2) NOT NULL CONSTRAINT CK_venta_precio CHECK (precio_usd > 0)
);

CREATE INDEX ix_venta_cliente ON venta (id_cliente);
CREATE INDEX ix_venta_fecha   ON venta (fecha_venta);
GO

-- ---------------------------------------------------------------------
-- 7. Vistas que alimentan el tablero
-- ---------------------------------------------------------------------

-- Lista de vehículos en stock (nivel 3 del drill-down)
CREATE VIEW v_vehiculos_en_stock AS
SELECT v.id_vehiculo,
       m.nombre       AS nombre,
       v.chasis       AS chasis,
       tm.descripcion AS motor,
       v.fecha_ingreso,
       DATEDIFF(DAY, v.fecha_ingreso, CAST(SYSDATETIME() AS DATE)) AS dias_en_stock,
       p.id_provincia,
       p.nombre       AS provincia,
       l.id_localidad,
       l.nombre       AS localidad,
       s.id_sucursal,
       s.nombre       AS sucursal
FROM vehiculo v
JOIN modelo     m  ON m.id_modelo      = v.id_modelo
JOIN tipo_motor tm ON tm.id_tipo_motor = m.id_tipo_motor
JOIN sucursal   s  ON s.id_sucursal    = v.id_sucursal
JOIN localidad  l  ON l.id_localidad   = s.id_localidad
JOIN provincia  p  ON p.id_provincia   = l.id_provincia
WHERE v.estado = 'EN_STOCK';
GO

-- Stock por sucursal con SEMÁFORO de 3 estados (nivel 2 del drill-down)
--   ROJO     : stock <  stock_minimo                 -> situación crítica, reponer ya
--   AMARILLO : stock entre stock_minimo y mínimo + 1 -> advertencia, al límite
--   VERDE    : stock >  stock_minimo + 1             -> situación normal
CREATE VIEW v_stock_por_sucursal AS
SELECT s.id_sucursal,
       s.nombre       AS sucursal,
       p.id_provincia,
       p.nombre       AS provincia,
       l.id_localidad,
       l.nombre       AS localidad,
       COUNT(v.id_vehiculo) AS stock,
       s.stock_minimo,
       CASE
           WHEN COUNT(v.id_vehiculo) <  s.stock_minimo     THEN 'ROJO'
           WHEN COUNT(v.id_vehiculo) <= s.stock_minimo + 1 THEN 'AMARILLO'
           ELSE 'VERDE'
       END AS semaforo
FROM sucursal s
JOIN localidad l ON l.id_localidad = s.id_localidad
JOIN provincia p ON p.id_provincia = l.id_provincia
LEFT JOIN vehiculo v ON v.id_sucursal = s.id_sucursal AND v.estado = 'EN_STOCK'
GROUP BY s.id_sucursal, s.nombre, p.id_provincia, p.nombre, l.id_localidad, l.nombre, s.stock_minimo;
GO

-- Resumen por provincia (nivel 1 del drill-down)
CREATE VIEW v_resumen_provincia AS
SELECT sp.id_provincia,
       sp.provincia,
       COUNT(*)                                             AS sucursales,
       SUM(sp.stock)                                        AS stock,
       SUM(CASE WHEN sp.semaforo = 'ROJO' THEN 1 ELSE 0 END) AS sucursales_en_rojo
FROM v_stock_por_sucursal sp
GROUP BY sp.id_provincia, sp.provincia;
GO

-- Ventas con todos sus datos (para indicadores de ventas)
CREATE VIEW v_ventas AS
SELECT ve.id_venta,
       ve.fecha_venta,
       ve.precio_usd,
       m.nombre                     AS modelo,
       s.id_sucursal,
       s.nombre                     AS sucursal,
       p.id_provincia,
       p.nombre                     AS provincia,
       c.id_cliente,
       c.apellido + N', ' + c.nombre AS cliente
FROM venta ve
JOIN vehiculo v ON v.id_vehiculo  = ve.id_vehiculo
JOIN modelo   m ON m.id_modelo    = v.id_modelo
JOIN sucursal s ON s.id_sucursal  = v.id_sucursal
JOIN localidad l ON l.id_localidad = s.id_localidad
JOIN provincia p ON p.id_provincia = l.id_provincia
JOIN cliente  c ON c.id_cliente   = ve.id_cliente;
GO

-- Total "Vehículos en stock" del tablero principal
CREATE VIEW v_total_stock AS
SELECT COUNT(*) AS vehiculos_en_stock
FROM vehiculo
WHERE estado = 'EN_STOCK';
GO

-- =====================================================================
-- 8. DATOS INICIALES
-- =====================================================================
INSERT INTO provincia (nombre) VALUES (N'Santa Fe'), (N'Buenos Aires'), (N'Córdoba');

INSERT INTO localidad (id_provincia, nombre) VALUES
    ((SELECT id_provincia FROM provincia WHERE nombre = N'Santa Fe'),     N'Rosario'),
    ((SELECT id_provincia FROM provincia WHERE nombre = N'Santa Fe'),     N'Santa Fe Capital'),
    ((SELECT id_provincia FROM provincia WHERE nombre = N'Buenos Aires'), N'Rojas'),
    ((SELECT id_provincia FROM provincia WHERE nombre = N'Buenos Aires'), N'La Plata'),
    ((SELECT id_provincia FROM provincia WHERE nombre = N'Buenos Aires'), N'Mar del Plata'),
    ((SELECT id_provincia FROM provincia WHERE nombre = N'Córdoba'),      N'Córdoba Ciudad'),
    ((SELECT id_provincia FROM provincia WHERE nombre = N'Córdoba'),      N'Villa María');

INSERT INTO tipo_motor (descripcion) VALUES
    (N'4.0L Bóxer 6 cilindros atmosférico'),
    (N'3.0L Bóxer 6 cilindros biturbo'),
    (N'3.7L Bóxer 6 cilindros biturbo');

-- Los id_modelo quedan 1..6 en este orden (se usan en los INSERT de vehiculo)
INSERT INTO modelo (nombre, id_tipo_motor) VALUES
    (N'911 GT3',            (SELECT id_tipo_motor FROM tipo_motor WHERE descripcion LIKE N'4.0L%')),  -- 1
    (N'911 GT3 RS',         (SELECT id_tipo_motor FROM tipo_motor WHERE descripcion LIKE N'4.0L%')),  -- 2
    (N'911 Turbo',          (SELECT id_tipo_motor FROM tipo_motor WHERE descripcion LIKE N'3.7L%')),  -- 3
    (N'911 Turbo S',        (SELECT id_tipo_motor FROM tipo_motor WHERE descripcion LIKE N'3.7L%')),  -- 4
    (N'911 Carrera S',      (SELECT id_tipo_motor FROM tipo_motor WHERE descripcion LIKE N'3.0L%')),  -- 5
    (N'718 Cayman GT4 RS',  (SELECT id_tipo_motor FROM tipo_motor WHERE descripcion LIKE N'4.0L%'));  -- 6

-- Los id_sucursal quedan 1..7 en este orden.
-- Los stocks están pensados para que el semáforo muestre los 3 colores.
INSERT INTO sucursal (nombre, id_localidad, stock_minimo) VALUES
    (N'Sucursal Rosario',        (SELECT id_localidad FROM localidad WHERE nombre = N'Rosario'),          3),  -- 1: stock 6 -> VERDE
    (N'Sucursal Santa Fe',       (SELECT id_localidad FROM localidad WHERE nombre = N'Santa Fe Capital'), 3),  -- 2: stock 3 -> AMARILLO
    (N'Sucursal Rojas',          (SELECT id_localidad FROM localidad WHERE nombre = N'Rojas'),            2),  -- 3: stock 1 -> ROJO
    (N'Sucursal La Plata',       (SELECT id_localidad FROM localidad WHERE nombre = N'La Plata'),         2),  -- 4: stock 5 -> VERDE
    (N'Sucursal Mar del Plata',  (SELECT id_localidad FROM localidad WHERE nombre = N'Mar del Plata'),    3),  -- 5: stock 2 -> ROJO
    (N'Sucursal Córdoba',        (SELECT id_localidad FROM localidad WHERE nombre = N'Córdoba Ciudad'),   2),  -- 6: stock 3 -> AMARILLO
    (N'Sucursal Villa María',    (SELECT id_localidad FROM localidad WHERE nombre = N'Villa María'),      2);  -- 7: stock 6 -> VERDE

-- Los id_cliente quedan 1..12
INSERT INTO cliente (nombre, apellido, dni, email, id_localidad) VALUES
    (N'Martín',    N'Gómez',     '30111222', 'mgomez@mail.com',     (SELECT id_localidad FROM localidad WHERE nombre = N'Rosario')),
    (N'Lucía',     N'Fernández', '31222333', 'lfernandez@mail.com', (SELECT id_localidad FROM localidad WHERE nombre = N'Rosario')),
    (N'Diego',     N'Pérez',     '28333444', 'dperez@mail.com',     (SELECT id_localidad FROM localidad WHERE nombre = N'Santa Fe Capital')),
    (N'Carolina',  N'López',     '33444555', 'clopez@mail.com',     (SELECT id_localidad FROM localidad WHERE nombre = N'Rojas')),
    (N'Javier',    N'Martínez',  '27555666', 'jmartinez@mail.com',  (SELECT id_localidad FROM localidad WHERE nombre = N'La Plata')),
    (N'Sofía',     N'Romero',    '35666777', 'sromero@mail.com',    (SELECT id_localidad FROM localidad WHERE nombre = N'La Plata')),
    (N'Federico',  N'Sosa',      '29777888', 'fsosa@mail.com',      (SELECT id_localidad FROM localidad WHERE nombre = N'Mar del Plata')),
    (N'Valentina', N'Torres',    '36888999', 'vtorres@mail.com',    (SELECT id_localidad FROM localidad WHERE nombre = N'Córdoba Ciudad')),
    (N'Nicolás',   N'Díaz',      '32999000', 'ndiaz@mail.com',      (SELECT id_localidad FROM localidad WHERE nombre = N'Córdoba Ciudad')),
    (N'Camila',    N'Ruiz',      '34000111', 'cruiz@mail.com',      (SELECT id_localidad FROM localidad WHERE nombre = N'Villa María')),
    (N'Agustín',   N'Álvarez',   '26111333', 'aalvarez@mail.com',   (SELECT id_localidad FROM localidad WHERE nombre = N'Rosario')),
    (N'Florencia', N'Benítez',   '37222444', 'fbenitez@mail.com',   (SELECT id_localidad FROM localidad WHERE nombre = N'Mar del Plata'));

-- Vehículos: id_modelo 1..6, id_sucursal 1..7
INSERT INTO vehiculo (chasis, id_modelo, id_sucursal, estado, fecha_ingreso, fecha_egreso) VALUES
    ('WP0ZZZ99ZNS100001', 3, 1, 'VENDIDO'  , '2025-11-17', '2026-01-16'),
    ('WP0ZZZ99ZNS100002', 5, 1, 'VENDIDO'  , '2025-10-19', '2025-12-14'),
    ('WP0ZZZ99ZNS100003', 5, 1, 'VENDIDO'  , '2025-12-19', '2026-01-02'),
    ('WP0ZZZ99ZNS100004', 4, 1, 'VENDIDO'  , '2025-10-06', '2025-11-15'),
    ('WP0ZZZ99ZNS100005', 4, 1, 'EN_STOCK' , '2025-10-01', NULL),
    ('WP0ZZZ99ZNS100006', 5, 1, 'EN_STOCK' , '2025-11-03', NULL),
    ('WP0ZZZ99ZNS100007', 2, 1, 'EN_STOCK' , '2026-07-20', NULL),
    ('WP0ZZZ99ZNS100008', 6, 1, 'EN_STOCK' , '2026-06-26', NULL),
    ('WP0ZZZ99ZNS100009', 1, 1, 'EN_STOCK' , '2026-06-23', NULL),
    ('WP0ZZZ99ZNS100010', 5, 1, 'EN_STOCK' , '2026-03-23', NULL),
    ('WP0ZZZ99ZNS100011', 1, 2, 'VENDIDO'  , '2025-12-23', '2026-01-07'),
    ('WP0ZZZ99ZNS100012', 3, 2, 'VENDIDO'  , '2026-04-03', '2026-05-01'),
    ('WP0ZZZ99ZNS100013', 5, 2, 'VENDIDO'  , '2026-02-05', '2026-04-27'),
    ('WP0ZZZ99ZNS100014', 5, 2, 'EN_STOCK' , '2026-06-20', NULL),
    ('WP0ZZZ99ZNS100015', 6, 2, 'EN_STOCK' , '2025-12-06', NULL),
    ('WP0ZZZ99ZNS100016', 3, 2, 'EN_STOCK' , '2025-10-20', NULL),
    ('WP0ZZZ99ZNS100017', 5, 3, 'VENDIDO'  , '2025-10-03', '2025-12-24'),
    ('WP0ZZZ99ZNS100018', 2, 3, 'VENDIDO'  , '2026-05-13', '2026-07-30'),
    ('WP0ZZZ99ZNS100019', 4, 3, 'VENDIDO'  , '2026-06-27', '2026-09-03'),
    ('WP0ZZZ99ZNS100020', 2, 3, 'EN_STOCK' , '2025-12-02', NULL),
    ('WP0ZZZ99ZNS100021', 6, 4, 'VENDIDO'  , '2026-01-03', '2026-01-23'),
    ('WP0ZZZ99ZNS100022', 5, 4, 'VENDIDO'  , '2026-05-12', '2026-07-04'),
    ('WP0ZZZ99ZNS100023', 5, 4, 'EN_STOCK' , '2025-10-08', NULL),
    ('WP0ZZZ99ZNS100024', 1, 4, 'EN_STOCK' , '2026-05-21', NULL),
    ('WP0ZZZ99ZNS100025', 4, 4, 'EN_STOCK' , '2025-11-24', NULL),
    ('WP0ZZZ99ZNS100026', 3, 4, 'EN_STOCK' , '2025-11-17', NULL),
    ('WP0ZZZ99ZNS100027', 4, 4, 'EN_STOCK' , '2026-04-04', NULL),
    ('WP0ZZZ99ZNS100028', 1, 5, 'VENDIDO'  , '2025-10-10', '2025-12-30'),
    ('WP0ZZZ99ZNS100029', 3, 5, 'VENDIDO'  , '2026-02-27', '2026-05-24'),
    ('WP0ZZZ99ZNS100030', 4, 5, 'VENDIDO'  , '2025-10-06', '2025-10-27'),
    ('WP0ZZZ99ZNS100031', 6, 5, 'EN_STOCK' , '2025-10-04', NULL),
    ('WP0ZZZ99ZNS100032', 1, 5, 'EN_STOCK' , '2026-02-06', NULL),
    ('WP0ZZZ99ZNS100033', 6, 6, 'VENDIDO'  , '2026-06-23', '2026-08-29'),
    ('WP0ZZZ99ZNS100034', 4, 6, 'VENDIDO'  , '2026-02-25', '2026-03-09'),
    ('WP0ZZZ99ZNS100035', 2, 6, 'EN_STOCK' , '2026-07-10', NULL),
    ('WP0ZZZ99ZNS100036', 1, 6, 'EN_STOCK' , '2026-05-11', NULL),
    ('WP0ZZZ99ZNS100037', 1, 6, 'EN_STOCK' , '2025-12-21', NULL),
    ('WP0ZZZ99ZNS100038', 3, 7, 'VENDIDO'  , '2025-11-06', '2025-12-17'),
    ('WP0ZZZ99ZNS100039', 4, 7, 'EN_STOCK' , '2025-10-12', NULL),
    ('WP0ZZZ99ZNS100040', 2, 7, 'EN_STOCK' , '2026-04-18', NULL),
    ('WP0ZZZ99ZNS100041', 4, 7, 'EN_STOCK' , '2026-06-09', NULL),
    ('WP0ZZZ99ZNS100042', 3, 7, 'EN_STOCK' , '2025-11-10', NULL),
    ('WP0ZZZ99ZNS100043', 4, 7, 'EN_STOCK' , '2026-06-09', NULL),
    ('WP0ZZZ99ZNS100044', 3, 7, 'EN_STOCK' , '2026-04-01', NULL);

-- Cada vehículo VENDIDO tiene su venta (misma fecha que fecha_egreso)
INSERT INTO venta (id_vehiculo, id_cliente, fecha_venta, precio_usd) VALUES
    (1, 2, '2026-01-16', 300000),
    (2, 1, '2025-12-14', 223000),
    (3, 7, '2026-01-02', 205000),
    (4, 9, '2025-11-15', 355000),
    (11, 3, '2026-01-07', 293000),
    (12, 2, '2026-05-01', 318000),
    (13, 2, '2026-04-27', 210000),
    (17, 10, '2025-12-24', 205000),
    (18, 6, '2026-07-30', 350000),
    (19, 5, '2026-09-03', 365000),
    (21, 5, '2026-01-23', 248000),
    (22, 5, '2026-07-04', 220000),
    (28, 6, '2025-12-30', 293000),
    (29, 10, '2026-05-24', 315000),
    (30, 8, '2025-10-27', 365000),
    (33, 12, '2026-08-29', 240000),
    (34, 6, '2026-03-09', 370000),
    (38, 7, '2025-12-17', 315000);


-- ---------------------------------------------------------------------
-- Usuario del tablero
--   usuario:    admin
--   contraseña: admin123
-- La contraseña se guarda con hash scrypt (formato: scrypt$<salt>$<hash>).
-- El servidor (paso 2) calcula el hash de lo que escribe el usuario y lo compara.
-- ---------------------------------------------------------------------
INSERT INTO usuario (login, password_hash) VALUES
    ('admin', 'scrypt$a18f3b7136f70a6401f5f0999c7a4644$4767cffab4b396448e453cf7fd30073c32192c4b75a69f32f8353ecf1991dd2e36c5df6e4ffb4adf42c02e76fe84ccc2f67282335f4322a2c06946b1c66511eb');
GO
