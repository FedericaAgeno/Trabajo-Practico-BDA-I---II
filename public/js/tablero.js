// =====================================================================
// Tablero GT3 — lógica de la página
//   Todos los datos vienen del servidor (/api/...), que los obtiene
//   de SQL Server con consultas SQL.
// =====================================================================

// ---------- Utilidades ----------
async function api(ruta) {
  const resp = await fetch(ruta);
  if (resp.status === 401) {            // sesión vencida → al login
    window.location.href = '/';
    throw new Error('No autenticado');
  }
  if (!resp.ok) throw new Error('Error del servidor');
  return resp.json();
}

const formatoUSD = new Intl.NumberFormat('es-AR', {
  style: 'currency', currency: 'USD', maximumFractionDigits: 0
});

function fecha(iso) {                    // '2026-03-12T00:00:00.000Z' → '12/03/2026'
  if (!iso) return '-';
  const [a, m, d] = String(iso).slice(0, 10).split('-');
  return `${d}/${m}/${a}`;
}

function escapar(texto) {                // evita que un dato rompa el HTML
  return String(texto ?? '').replace(/[&<>"']/g, c =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

const textoSemaforo = { VERDE: 'Normal', AMARILLO: 'Advertencia', ROJO: 'Crítico' };

function luz(estado) {
  return `<span class="luz ${estado}" title="${textoSemaforo[estado]}"></span>
          <span class="estado-texto">${textoSemaforo[estado]}</span>`;
}

// ---------- Estado de navegación (drill-down) ----------
// nivel 1 = provincias, 2 = sucursales de una provincia, 3 = vehículos de una sucursal
const estado = { nivel: 1, provincia: null, sucursal: null };

const $ = (id) => document.getElementById(id);

// ---------- Indicadores generales ----------
async function cargarKpis() {
  const k = await api('/api/kpis');
  $('kpiStock').textContent = k.en_stock;
  $('kpiVendidos').textContent = k.vendidos;
  $('kpiFacturado').textContent = formatoUSD.format(k.facturado_usd);
  $('kpiSemaforos').innerHTML = `
    <span class="kpi-sem"><span class="luz ROJO"></span>${k.sucursales_rojo}</span>
    <span class="kpi-sem"><span class="luz AMARILLO"></span>${k.sucursales_amarillo}</span>
    <span class="kpi-sem"><span class="luz VERDE"></span>${k.sucursales_verde}</span>`;
}

// ---------- Migas de pan + botón volver ----------
function dibujarMigas() {
  const partes = [`<a href="#" data-ir="1">Provincias</a>`];
  if (estado.provincia) {
    partes.push(estado.nivel === 2
      ? `<span>${escapar(estado.provincia.nombre)}</span>`
      : `<a href="#" data-ir="2">${escapar(estado.provincia.nombre)}</a>`);
  }
  if (estado.sucursal) partes.push(`<span>${escapar(estado.sucursal.nombre)}</span>`);
  $('migas').innerHTML = partes.join(' › ');
  $('btnVolver').hidden = estado.nivel === 1;
}

$('migas').addEventListener('click', (e) => {
  const enlace = e.target.closest('[data-ir]');
  if (!enlace) return;
  e.preventDefault();
  irANivel(Number(enlace.dataset.ir));
});

// Drill Up: volver al nivel anterior
$('btnVolver').addEventListener('click', () => irANivel(estado.nivel - 1));

function irANivel(nivel) {
  if (nivel <= 1) { estado.provincia = null; estado.sucursal = null; estado.nivel = 1; }
  else if (nivel === 2) { estado.sucursal = null; estado.nivel = 2; }
  mostrarNivel();
}

// ---------- Dibujo de cada nivel ----------
async function mostrarNivel() {
  dibujarMigas();
  $('tablaNivel').innerHTML = '<p class="cargando">Cargando…</p>';
  try {
    if (estado.nivel === 1) await nivelProvincias();
    else if (estado.nivel === 2) await nivelSucursales();
    else await nivelVehiculos();
  } catch (err) {
    $('tablaNivel').innerHTML = '<p class="error-tabla">No se pudieron cargar los datos.</p>';
  }
  cargarVentas();
}

// NIVEL 1
async function nivelProvincias() {
  $('tituloNivel').textContent = 'Stock por provincia';
  $('ayudaNivel').textContent = 'Hacé clic en una provincia para ver sus sucursales.';
  const filas = await api('/api/provincias');
  $('tablaNivel').innerHTML = `
    <table>
      <thead><tr>
        <th>Provincia</th><th class="num">Sucursales</th><th class="num">En stock</th>
        <th class="num">Vendidos</th><th class="num">Suc. en rojo</th><th>Estado</th>
      </tr></thead>
      <tbody>
        ${filas.map(f => `
          <tr class="clic" data-id="${f.id_provincia}" data-nombre="${escapar(f.provincia)}">
            <td><strong>${escapar(f.provincia)}</strong></td>
            <td class="num">${f.sucursales}</td>
            <td class="num">${f.stock}</td>
            <td class="num">${f.vendidos}</td>
            <td class="num">${f.en_rojo}</td>
            <td>${luz(f.semaforo)}</td>
          </tr>`).join('')}
      </tbody>
    </table>`;
  // Drill Down → nivel 2
  $('tablaNivel').querySelectorAll('tr.clic').forEach(tr => tr.addEventListener('click', () => {
    estado.provincia = { id: Number(tr.dataset.id), nombre: tr.dataset.nombre };
    estado.nivel = 2;
    mostrarNivel();
  }));
}

// NIVEL 2
async function nivelSucursales() {
  $('tituloNivel').textContent = `Sucursales de ${estado.provincia.nombre}`;
  $('ayudaNivel').textContent = 'Hacé clic en una sucursal para ver el detalle de sus vehículos en stock.';
  const filas = await api(`/api/provincias/${estado.provincia.id}/sucursales`);
  $('tablaNivel').innerHTML = `
    <table>
      <thead><tr>
        <th>Sucursal</th><th>Localidad</th><th class="num">En stock</th>
        <th class="num">Mínimo</th><th class="num">Vendidos</th><th>Semáforo</th>
      </tr></thead>
      <tbody>
        ${filas.map(f => `
          <tr class="clic fila-${f.semaforo}" data-id="${f.id_sucursal}" data-nombre="${escapar(f.sucursal)}">
            <td><strong>${escapar(f.sucursal)}</strong></td>
            <td>${escapar(f.localidad)}</td>
            <td class="num">${f.stock}</td>
            <td class="num">${f.stock_minimo}</td>
            <td class="num">${f.vendidos}</td>
            <td>${luz(f.semaforo)}</td>
          </tr>`).join('')}
      </tbody>
    </table>`;
  // Drill Down → nivel 3
  $('tablaNivel').querySelectorAll('tr.clic').forEach(tr => tr.addEventListener('click', () => {
    estado.sucursal = { id: Number(tr.dataset.id), nombre: tr.dataset.nombre };
    estado.nivel = 3;
    mostrarNivel();
  }));
}

// NIVEL 3
async function nivelVehiculos() {
  $('tituloNivel').textContent = `Vehículos en stock · ${estado.sucursal.nombre}`;
  $('ayudaNivel').textContent = 'Ordenados por antigüedad: los primeros son los que llevan más tiempo sin venderse.';
  const filas = await api(`/api/sucursales/${estado.sucursal.id}/vehiculos`);
  if (filas.length === 0) {
    $('tablaNivel').innerHTML = '<p class="vacio">Esta sucursal no tiene vehículos en stock.</p>';
    return;
  }
  $('tablaNivel').innerHTML = `
    <table>
      <thead><tr>
        <th>Modelo</th><th>Chasis</th><th>Motor</th>
        <th>Ingreso</th><th class="num">Días en stock</th>
      </tr></thead>
      <tbody>
        ${filas.map(f => `
          <tr>
            <td><strong>${escapar(f.modelo)}</strong></td>
            <td class="mono">${escapar(f.chasis)}</td>
            <td>${escapar(f.motor)}</td>
            <td>${fecha(f.fecha_ingreso)}</td>
            <td class="num">${f.dias_en_stock}</td>
          </tr>`).join('')}
      </tbody>
    </table>`;
}

// ---------- Gráfico de ventas por modelo (barras con HTML/CSS) ----------
async function cargarVentas() {
  let url = '/api/ventas-por-modelo';
  let alcance = 'todas las sucursales';
  if (estado.sucursal) {
    url += `?sucursal=${estado.sucursal.id}`;
    alcance = estado.sucursal.nombre;
  } else if (estado.provincia) {
    url += `?provincia=${estado.provincia.id}`;
    alcance = estado.provincia.nombre;
  }
  $('tituloVentas').textContent = `Ventas por modelo · ${alcance}`;

  try {
    const filas = await api(url);
    if (filas.length === 0) {
      $('graficoVentas').innerHTML = '<p class="vacio">Sin ventas registradas.</p>';
      return;
    }
    const max = Math.max(...filas.map(f => f.unidades));
    $('graficoVentas').innerHTML = filas.map(f => `
      <div class="barra-fila" title="${escapar(f.modelo)}: ${f.unidades} u. · ${formatoUSD.format(f.total_usd)}">
        <span class="barra-etiqueta">${escapar(f.modelo)}</span>
        <span class="barra-pista"><span class="barra" style="width:${(f.unidades / max) * 100}%"></span></span>
        <span class="barra-valor">${f.unidades}</span>
      </div>`).join('') +
      `<p class="nota">Unidades vendidas. Pasá el mouse por una barra para ver el monto en USD.</p>`;
  } catch {
    $('graficoVentas').innerHTML = '<p class="error-tabla">No se pudieron cargar las ventas.</p>';
  }
}

// ---------- Inicio ----------
$('btnSalir').addEventListener('click', async () => {
  await fetch('/api/logout', { method: 'POST' });
  window.location.href = '/';
});

(async () => {
  try {
    const yo = await api('/api/yo');
    $('nombreUsuario').textContent = 'Usuario: ' + yo.login;
    await cargarKpis();
  } catch { /* si no hay sesión, api() ya redirige */ }
  mostrarNivel();
})();
