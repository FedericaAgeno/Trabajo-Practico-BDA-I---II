// =====================================================================
// Servidor web del Tablero GT3
//   - Login contra la tabla "usuario" (contraseña con hash scrypt)
//   - Protege el tablero: sin sesión iniciada no se puede entrar
//   - Expone las consultas SQL como rutas /api/...
// =====================================================================
const path = require('path');
const crypto = require('crypto');
const express = require('express');
const session = require('express-session');

const config = require('./config');
const { consulta, obtenerPool } = require('./db');

const app = express();
app.use(express.json());
app.use(session({
  secret: config.secretoSesion,
  resave: false,
  saveUninitialized: false,
  cookie: { httpOnly: true, maxAge: 1000 * 60 * 60 * 2 } // 2 horas
}));

// ---------------------------------------------------------------------
// Contraseñas
// En la base se guarda:  scrypt$<salt>$<hash>
// Para verificar, calculamos el hash de lo que escribió el usuario con el
// mismo salt y lo comparamos con el guardado. La contraseña real nunca se guarda.
// ---------------------------------------------------------------------
function verificarPassword(passwordIngresada, hashGuardado) {
  const partes = String(hashGuardado).split('$');
  if (partes.length !== 3 || partes[0] !== 'scrypt') return false;
  const [, salt, hashHex] = partes;
  const esperado = Buffer.from(hashHex, 'hex');
  const calculado = crypto.scryptSync(passwordIngresada, salt, esperado.length);
  return crypto.timingSafeEqual(esperado, calculado);
}

// ---------------------------------------------------------------------
// Middleware: solo deja pasar si hay sesión iniciada
// ---------------------------------------------------------------------
function requiereLogin(req, res, next) {
  if (req.session.usuario) return next();
  if (req.path.startsWith('/api/')) {
    return res.status(401).json({ error: 'No autenticado' });
  }
  return res.redirect('/');
}

// ---------------------------------------------------------------------
// Páginas
// ---------------------------------------------------------------------
// Inicio: si ya inició sesión va al tablero, si no, al login
app.get('/', (req, res) => {
  if (req.session.usuario) return res.redirect('/tablero');
  res.sendFile(path.join(__dirname, 'public', 'login.html'));
});

// El tablero está en la carpeta "privado": solo se entrega con sesión
app.get('/tablero', requiereLogin, (req, res) => {
  res.sendFile(path.join(__dirname, 'privado', 'tablero.html'));
});

// Archivos públicos (CSS, imágenes, JS del login)
app.use(express.static(path.join(__dirname, 'public')));

// ---------------------------------------------------------------------
// Login / Logout
// ---------------------------------------------------------------------
app.post('/api/login', async (req, res) => {
  const { usuario, password } = req.body || {};
  if (!usuario || !password) {
    return res.status(400).json({ error: 'Ingresá usuario y contraseña' });
  }
  try {
    const filas = await consulta(
      `SELECT id_usuario, login, password_hash
         FROM usuario
        WHERE login = @login AND activo = 1`,
      { login: usuario }
    );
    const u = filas[0];
    if (!u || !verificarPassword(password, u.password_hash)) {
      // Mismo mensaje para usuario o contraseña incorrectos (no da pistas)
      return res.status(401).json({ error: 'Usuario o contraseña incorrectos' });
    }
    req.session.usuario = { id: u.id_usuario, login: u.login };
    res.json({ ok: true });
  } catch (err) {
    console.error('Error en login:', err.message);
    res.status(500).json({ error: 'No se pudo conectar con la base de datos' });
  }
});

app.post('/api/logout', (req, res) => {
  req.session.destroy(() => res.json({ ok: true }));
});

// Todo lo que sigue requiere sesión iniciada
app.use('/api', requiereLogin);

app.get('/api/yo', (req, res) => {
  res.json(req.session.usuario);
});

// ---------------------------------------------------------------------
// Consultas del tablero
// ---------------------------------------------------------------------
// Envuelve cada ruta para manejar errores en un solo lugar
const ruta = (fn) => async (req, res) => {
  try {
    res.json(await fn(req));
  } catch (err) {
    console.error('Error SQL:', err.message);
    res.status(500).json({ error: 'Error al consultar la base' });
  }
};

// Convierte un parámetro de la URL en número entero (o null si no es válido)
const entero = (valor) => {
  const n = Number.parseInt(valor, 10);
  return Number.isInteger(n) && n > 0 ? n : null;
};

// --- Indicadores generales (tarjetas de arriba) ---
app.get('/api/kpis', ruta(async () => {
  const filas = await consulta(`
    SELECT
      (SELECT vehiculos_en_stock FROM v_total_stock)                         AS en_stock,
      (SELECT COUNT(*)                FROM venta)                            AS vendidos,
      (SELECT ISNULL(SUM(precio_usd), 0) FROM venta)                         AS facturado_usd,
      (SELECT COUNT(*) FROM v_stock_por_sucursal WHERE semaforo = 'ROJO')     AS sucursales_rojo,
      (SELECT COUNT(*) FROM v_stock_por_sucursal WHERE semaforo = 'AMARILLO') AS sucursales_amarillo,
      (SELECT COUNT(*) FROM v_stock_por_sucursal WHERE semaforo = 'VERDE')    AS sucursales_verde
  `);
  return filas[0];
}));

// --- Drill-down NIVEL 1: provincias ---
// El color de la provincia es el de su peor sucursal.
app.get('/api/provincias', ruta(async () => {
  return consulta(`
    WITH ventas_prov AS (
      SELECT id_provincia, COUNT(*) AS vendidos
      FROM v_ventas
      GROUP BY id_provincia
    )
    SELECT sp.id_provincia,
           sp.provincia,
           COUNT(*)                                                    AS sucursales,
           SUM(sp.stock)                                               AS stock,
           SUM(CASE WHEN sp.semaforo = 'ROJO'     THEN 1 ELSE 0 END)   AS en_rojo,
           SUM(CASE WHEN sp.semaforo = 'AMARILLO' THEN 1 ELSE 0 END)   AS en_amarillo,
           ISNULL(MAX(vp.vendidos), 0)                                 AS vendidos,
           CASE
             WHEN SUM(CASE WHEN sp.semaforo = 'ROJO'     THEN 1 ELSE 0 END) > 0 THEN 'ROJO'
             WHEN SUM(CASE WHEN sp.semaforo = 'AMARILLO' THEN 1 ELSE 0 END) > 0 THEN 'AMARILLO'
             ELSE 'VERDE'
           END                                                         AS semaforo
    FROM v_stock_por_sucursal sp
    LEFT JOIN ventas_prov vp ON vp.id_provincia = sp.id_provincia
    GROUP BY sp.id_provincia, sp.provincia
    ORDER BY sp.provincia
  `);
}));

// --- Drill-down NIVEL 2: sucursales de una provincia ---
app.get('/api/provincias/:id/sucursales', ruta(async (req) => {
  const id = entero(req.params.id);
  if (!id) return [];
  return consulta(`
    SELECT sp.id_sucursal,
           sp.sucursal,
           sp.localidad,
           sp.stock,
           sp.stock_minimo,
           sp.semaforo,
           ISNULL(vt.vendidos, 0) AS vendidos
    FROM v_stock_por_sucursal sp
    LEFT JOIN (SELECT id_sucursal, COUNT(*) AS vendidos
                 FROM v_ventas
                GROUP BY id_sucursal) vt ON vt.id_sucursal = sp.id_sucursal
    WHERE sp.id_provincia = @id
    ORDER BY sp.sucursal
  `, { id });
}));

// --- Drill-down NIVEL 3: vehículos en stock de una sucursal ---
app.get('/api/sucursales/:id/vehiculos', ruta(async (req) => {
  const id = entero(req.params.id);
  if (!id) return [];
  return consulta(`
    SELECT nombre AS modelo,
           chasis,
           motor,
           fecha_ingreso,
           dias_en_stock
    FROM v_vehiculos_en_stock
    WHERE id_sucursal = @id
    ORDER BY dias_en_stock DESC
  `, { id });
}));

// --- Ventas por modelo (gráfico). Se filtra según el nivel en que está el usuario ---
app.get('/api/ventas-por-modelo', ruta(async (req) => {
  const provincia = entero(req.query.provincia);
  const sucursal = entero(req.query.sucursal);
  let filtro = '';
  const params = {};
  if (sucursal) {
    filtro = 'WHERE id_sucursal = @sucursal';
    params.sucursal = sucursal;
  } else if (provincia) {
    filtro = 'WHERE id_provincia = @provincia';
    params.provincia = provincia;
  }
  return consulta(`
    SELECT modelo,
           COUNT(*)        AS unidades,
           SUM(precio_usd) AS total_usd
    FROM v_ventas
    ${filtro}
    GROUP BY modelo
    ORDER BY unidades DESC, total_usd DESC
  `, params);
}));

// ---------------------------------------------------------------------
// Arranque
// ---------------------------------------------------------------------
app.listen(config.puertoWeb, async () => {
  console.log(`\n  Tablero GT3 corriendo en:  http://localhost:${config.puertoWeb}\n`);
  try {
    await obtenerPool();
  } catch (err) {
    console.error('✘ No se pudo conectar a SQL Server:', err.message);
    console.error('  Revisá config.js y que SQL Server tenga TCP/IP habilitado en el puerto 1433.');
  }
});
