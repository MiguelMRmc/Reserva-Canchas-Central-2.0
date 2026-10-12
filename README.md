# Central Pádel · Reserva de Canchas Online

Página web de reservas con **registro en base de datos**: cada turno queda guardado y **el sistema impide asignar dos veces la misma cancha en horarios que se cruzan**, aunque dos personas aprieten "Reservar" en el mismo segundo.

- **Jugadores**: ven la disponibilidad en vivo, reservan desde el celular y reciben un **código** (`R-ABC123`) para consultar o cancelar con su RUT.
- **Administración**: agenda por día, confirmar pagos, reservas del club, bloqueos, búsqueda por nombre/RUT/código, ajustes de precios y datos de pago.
- **Sin servidor propio**: la página es un archivo estático (GitHub Pages) y los datos viven en Supabase (plan gratuito alcanza para un club).

## Cómo funciona el "no repetir turno"

| Capa | Qué hace |
|---|---|
| Base de datos | Restricción de exclusión (`reservas_sin_solape`): misma cancha + horarios que se cruzan = prohibido. Las reservas **canceladas** no cuentan, así que el turno se puede volver a tomar. |
| Reserva online | El servidor valida todo otra vez (RUT, horario, anticipación, cancha) y **calcula el precio él mismo**; el navegador no puede alterarlo. |
| Pagos pendientes | Una reserva online sin pagar se libera sola a las N horas (ajustable, por defecto 4). Las pagadas nunca vencen. |
| Historial | Tabla `reservas_historial`: quién y cuándo creó, modificó, canceló o eliminó cada turno. |
| Privacidad | El público solo ve "ocupado / libre". Nombres, RUT, teléfonos y correos los ve únicamente el administrador. |

## Puesta en marcha (≈ 15 minutos)

### 1. Crear la base de datos (Supabase)
1. Crea una cuenta en <https://supabase.com> → **New project** (región más cercana, p. ej. São Paulo). Guarda la contraseña de la base de datos.
2. Menú **SQL Editor → New query**, pega **todo** el contenido de `supabase/reservas.sql` y presiona **Run**. Debe terminar sin errores (se puede ejecutar más de una vez).

### 2. Crear al administrador
1. **Authentication → Users → Add user → Create new user**: tu correo y una contraseña fuerte, marcando **Auto Confirm User**.
2. **SQL Editor**, ejecuta (con tu correo):
   ```sql
   insert into public.reservas_admins (email) values ('tu-correo@ejemplo.cl');
   ```
   Solo los correos de esa tabla tienen acceso al panel. Para sumar otro administrador, repite ambos pasos.
3. Recomendado: **Authentication → Sign In / Providers → desactivar "Allow new users to sign up"**.

### 3. Conectar la página
1. **Project Settings → API**: copia **Project URL** y la clave **anon public**.
2. Edita `config.js` y pégalas entre las comillas. **No uses la clave `service_role`** ni la subas a ningún lado.

### 4. Publicar en GitHub Pages
1. En <https://github.com> crea un repositorio (**Public**: Pages gratis lo exige; el contenido no contiene secretos).
2. **Add file → Upload files** y sube **todo** el contenido de esta carpeta (`index.html`, `config.js`, `.nojekyll`, `supabase/`, `README.md`). No necesitas Git instalado.
3. **Settings → Pages → Build and deployment**: *Deploy from a branch* → `main` / `/ (root)` → Save.
4. En 1–2 minutos queda en `https://TU-USUARIO.github.io/NOMBRE-REPO/`. Ese es el enlace que compartes por WhatsApp o Instagram.

> Alternativa sin cuenta de GitHub: arrastra la carpeta a <https://app.netlify.com/drop>.

### 5. Primera configuración
Abre el enlace → **Administrador** → ingresa con tu correo y contraseña → **Ajustes**: nombre, canchas, **datos de pago** (los ve el jugador al reservar), contacto, horario, precios por bloque y horas para pagar.

### 6. Prueba antes de anunciar
1. Como jugador, reserva un turno de mañana: debe aparecer el código.
2. Abre la página en otro celular o ventana e intenta el mismo turno: debe aparecer ocupado.
3. En el panel, confirma el pago, crea un bloqueo y revisa que el jugador lo vea "Ocupado".

## Uso diario
- **Pago**: el jugador transfiere (datos en Ajustes) y tú presionas **Confirmar pago** en *Reservas*. Pago online (Mercado Pago / Webpay) sería una etapa posterior.
- **Reservas por teléfono / mesón**: en *Agenda* toca un horario libre → queda registrada con origen "club" y no vence.
- **Cambios**: *Editar* o *Reagendar*; si el nuevo turno está ocupado, el sistema lo rechaza.
- **Respaldo**: *Ajustes → Descargar respaldo JSON* y *Reservas → Exportar CSV* cada cierto tiempo.
- **Historial**: Supabase → Table Editor → `reservas_historial`.

## Cosas a tener en cuenta
- **Plan gratuito de Supabase**: el proyecto se pausa tras ~1 semana sin actividad (se reactiva desde el panel de Supabase). Con reservas diarias no ocurre.
- **No renombres una cancha** que ya tiene reservas: las antiguas conservarían el nombre anterior.
- **Abuso**: máximo 2 reservas online pendientes por RUT, campo trampa para robots y vencimiento automático. Si algún día hay spam, reduce las "horas para pagar" o pide confirmación por WhatsApp.
- **Vista del administrador en el celular** funciona, pero la agenda se ve mejor en pantalla grande.
- **Hora de Chile**: el servidor valida con la zona `America/Santiago` (columna `zona` de `reservas_config`).
- Sin `config.js` configurado, la página sigue funcionando **sin conexión** (datos solo en ese navegador, clave local `admin / padel2026`): sirve para probar.

## Estructura
```
index.html            ← la aplicación completa (un solo archivo)
config.js             ← URL y clave pública de Supabase
supabase/reservas.sql ← tablas, reglas de seguridad y funciones
.nojekyll             ← evita que GitHub procese el sitio
```
