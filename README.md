# Tablero de Control – Concesionaria GT3

Trabajo Práctico Final de **Base de Datos Aplicada** (UAI).
Integrantes: **Federica Ageno** y **Franco Turri**.

Tablero web que muestra el stock y las ventas de una concesionaria de autos deportivos,
con datos obtenidos de SQL Server mediante consultas SQL.

## Funcionalidades
- **Login** contra la tabla `usuario` (contraseña guardada con hash scrypt) y páginas protegidas.
- **Indicadores**: vehículos en stock, unidades vendidas, total facturado y estado de las sucursales.
- **Semáforo de stock** (rojo / amarillo / verde) por sucursal, con leyenda.
- **Drill Down / Drill Up** en 3 niveles: Provincias → Sucursales → Vehículos.
- **Gráfico de ventas por modelo**, filtrado según el nivel en que se encuentra el usuario.

## Tecnologías
SQL Server Express · Node.js · Express · mssql · express-session · HTML / CSS / JavaScript

## Estructura
```
database/gt3.sql      Script de la base (tablas, vistas y datos con INSERT)
server.js             Servidor: login, sesiones y consultas SQL (/api/...)
db.js                 Conexión a SQL Server
config.js             Datos de conexión y puerto
public/               Login, estilos, imágenes y JS del tablero
privado/tablero.html  Tablero (solo accesible con sesión iniciada)
```

## Cómo ejecutarlo
1. Ejecutar `database/gt3.sql` completo en SQL Server Management Studio.
2. En SQL Server: habilitar autenticación de SQL Server y Windows, habilitar TCP/IP en el puerto 1433
   y crear el usuario de la aplicación:
   ```sql
   USE master;
   CREATE LOGIN gt3_app WITH PASSWORD = 'Gt3App2026!', CHECK_POLICY = OFF;
   GO
   USE GT3;
   CREATE USER gt3_app FOR LOGIN gt3_app;
   ALTER ROLE db_datareader ADD MEMBER gt3_app;
   ```
3. En la carpeta del proyecto:
   ```
   npm install
   npm start
   ```
4. Abrir http://localhost:3000 — usuario `admin`, contraseña `admin123`.
