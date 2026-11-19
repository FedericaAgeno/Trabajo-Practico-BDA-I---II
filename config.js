// =====================================================================
// Configuración de la conexión a SQL Server
// Si cambiás el usuario, la contraseña o el puerto, cambialo acá.
// =====================================================================
module.exports = {
  db: {
    server: 'localhost',
    port: 1433,                 // puerto fijo que configuramos en IPAll
    database: 'GT3',
    user: 'gt3_app',            // usuario de solo lectura creado en SSMS
    password: 'Gt3App2026!',
    options: {
      encrypt: false,           // conexión local, no hace falta cifrar
      trustServerCertificate: true
    }
  },

  // Puerto donde corre la página: http://localhost:3000
  puertoWeb: 3000,

  // Clave para firmar la cookie de sesión (puede ser cualquier texto largo)
  secretoSesion: 'gt3-tp-bda-clave-secreta-de-sesion'
};
