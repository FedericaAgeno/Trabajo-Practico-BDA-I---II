// =====================================================================
// Conexión a SQL Server (una sola conexión compartida: "pool")
// =====================================================================
const sql = require('mssql');
const config = require('./config');

let poolPromise = null;

function obtenerPool() {
  if (!poolPromise) {
    poolPromise = new sql.ConnectionPool(config.db)
      .connect()
      .then(pool => {
        console.log('✔ Conectado a SQL Server (base GT3)');
        return pool;
      })
      .catch(err => {
        poolPromise = null; // permite reintentar en el próximo pedido
        throw err;
      });
  }
  return poolPromise;
}

// Ejecuta una consulta SQL con parámetros.
//   consulta('SELECT * FROM x WHERE id = @id', { id: 5 })
// Los parámetros se pasan aparte (nunca concatenados) para evitar inyección SQL.
async function consulta(textoSql, parametros = {}) {
  const pool = await obtenerPool();
  const request = pool.request();
  for (const [nombre, valor] of Object.entries(parametros)) {
    request.input(nombre, valor);
  }
  const resultado = await request.query(textoSql);
  return resultado.recordset;
}

module.exports = { consulta, obtenerPool };
