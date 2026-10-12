-- =====================================================================
--  Central Pádel · Reserva de Canchas ONLINE  ·  Esquema Supabase (PostgreSQL)
--  Pégalo completo en Supabase → SQL Editor → Run.  Se puede ejecutar más de una vez.
--
--  Garantía clave: la BASE DE DATOS impide que dos reservas ocupen la misma
--  cancha en horarios que se cruzan (restricción de exclusión). Aunque dos
--  personas aprieten "Reservar" en el mismo segundo, solo una queda registrada.
--
--  Seguridad: el público NO lee ni escribe tablas; solo usa las funciones de la
--  sección 5. Los datos personales de los jugadores solo los ve el administrador.
-- =====================================================================

create extension if not exists btree_gist;

-- ---------- 1. TABLAS ----------

-- Quién es administrador (correos que existen en Authentication → Users)
create table if not exists public.reservas_admins (
  email text primary key
);

-- Configuración del club (una sola fila)
create table if not exists public.reservas_config (
  id               int primary key default 1 check (id = 1),
  nombre           text    not null default 'Central Pádel Chillán',
  canchas          text[]  not null default array['Cancha 1','Cancha 2','Cancha 3','Central'],
  datos_pago       text    not null default '',
  contacto         text    not null default '',
  duracion_min     int     not null default 90   check (duracion_min between 30 and 240),
  anticipacion_max int     not null default 5    check (anticipacion_max between 1 and 60),
  hora_apertura    time    not null default '08:00',
  hora_cierre      time    not null default '23:30',
  bloquear_pasados boolean not null default true,
  horas_pago       int     not null default 4    check (horas_pago between 0 and 72),  -- 0 = no vencen
  zona             text    not null default 'America/Santiago',
  precios          jsonb   not null default '[
    {"nombre":"Valle","desde":"08:00","hasta":"17:00","precio":12000},
    {"nombre":"Punta","desde":"17:00","hasta":"22:00","precio":20000},
    {"nombre":"Nocturno","desde":"22:00","hasta":"23:30","precio":15000}]'::jsonb
);
insert into public.reservas_config (id) values (1) on conflict do nothing;

-- Reservas y bloqueos (mismo tabla = una sola restricción protege ambos)
create table if not exists public.reservas (
  id          uuid primary key default gen_random_uuid(),
  codigo      text unique,
  tipo        text not null default 'reserva' check (tipo in ('reserva','bloqueo')),
  origen      text not null default 'club'    check (origen in ('club','online')),
  cancha      text not null,
  fecha       date not null,
  hora        time not null,
  duracion    int  not null check (duracion between 30 and 480),
  estado      text not null default 'pendiente' check (estado in ('pendiente','confirmada','cancelada')),
  precio      int  not null default 0 check (precio >= 0),
  nombre      text, rut text, fono text, email text,
  jugadores   jsonb not null default '[]'::jsonb,
  motivo      text,
  vence       timestamptz,                       -- solo reservas online pendientes
  creada      timestamptz not null default now(),
  actualizada timestamptz not null default now(),
  periodo     tsrange generated always as
              (tsrange(fecha + hora, fecha + hora + duracion * interval '1 minute')) stored,
  check (tipo = 'bloqueo' or (nombre is not null and length(trim(nombre)) >= 3 and rut is not null and fono is not null and email is not null)),
  -- ★ LA GARANTÍA: misma cancha + horarios que se cruzan = prohibido (las canceladas no cuentan)
  constraint reservas_sin_solape exclude using gist (cancha with =, periodo with &&) where (estado <> 'cancelada')
);
create index if not exists reservas_fecha_idx on public.reservas (fecha);
create index if not exists reservas_rut_idx   on public.reservas (rut);

-- Historial de cambios (quién y cuándo creó, cambió o canceló cada turno)
create table if not exists public.reservas_historial (
  id         bigint generated always as identity primary key,
  reserva_id uuid,
  accion     text not null,
  antes      jsonb,
  despues    jsonb,
  quien      text,
  cuando     timestamptz not null default now()
);
create index if not exists reservas_historial_res_idx on public.reservas_historial (reserva_id);

-- ---------- 2. FUNCIONES AUXILIARES ----------

create or replace function public.res_rut_limpio(t text) returns text
language sql immutable as $$ select upper(regexp_replace(coalesce(t, ''), '[^0-9kK]', '', 'g')) $$;

create or replace function public.res_rut_valido(t text) returns boolean
language plpgsql immutable as $$
declare l text := public.res_rut_limpio(t); cuerpo text; s int := 0; m int := 2; r int; dv text;
begin
  if length(l) < 8 or length(l) > 9 then return false; end if;
  cuerpo := left(l, -1);
  if cuerpo !~ '^[0-9]+$' then return false; end if;
  for i in reverse length(cuerpo)..1 loop
    s := s + substr(cuerpo, i, 1)::int * m;
    m := case when m = 7 then 2 else m + 1 end;
  end loop;
  r := 11 - (s % 11);
  dv := case when r = 11 then '0' when r = 10 then 'K' else r::text end;
  return right(l, 1) = dv;
end $$;

create or replace function public.res_rut_formato(t text) returns text
language plpgsql immutable as $$
declare l text := public.res_rut_limpio(t); cuerpo text; salida text := ''; n int;
begin
  cuerpo := left(l, -1); n := length(cuerpo);
  for i in 1..n loop
    salida := salida || substr(cuerpo, i, 1);
    if (n - i) % 3 = 0 and i < n then salida := salida || '.'; end if;
  end loop;
  return salida || '-' || right(l, 1);
end $$;

create or replace function public.res_fono_valido(t text) returns boolean
language sql immutable as $$ select regexp_replace(coalesce(t, ''), '[\s\-()]', '', 'g') ~ '^(\+?56)?9[0-9]{8}$' $$;

create or replace function public.res_codigo() returns text
language plpgsql volatile as $$
declare a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text := 'R-'; i int;
begin
  for i in 1..6 loop c := c || substr(a, 1 + floor(random() * length(a))::int, 1); end loop;
  return c;
end $$;

-- ¿La persona conectada es administradora? (lee el correo del token de Supabase Auth)
create or replace function public.es_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') = 'authenticated'
     and exists (select 1 from public.reservas_admins a
                 where lower(a.email) = lower(coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email', '')))
$$;

-- ---------- 3. DISPARADORES (marca de tiempo + historial) ----------

create or replace function public.reservas_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare quien text := coalesce(nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email', ''), 'público');
begin
  if tg_op = 'INSERT' then
    insert into public.reservas_historial (reserva_id, accion, despues, quien) values (new.id, 'crear', to_jsonb(new) - 'periodo', quien);
    return new;
  elsif tg_op = 'UPDATE' then
    new.actualizada := now();
    insert into public.reservas_historial (reserva_id, accion, antes, despues, quien)
    values (new.id, case when old.estado <> 'cancelada' and new.estado = 'cancelada' then 'cancelar' else 'modificar' end,
            to_jsonb(old) - 'periodo', to_jsonb(new) - 'periodo', quien);
    return new;
  else
    insert into public.reservas_historial (reserva_id, accion, antes, quien) values (old.id, 'eliminar', to_jsonb(old) - 'periodo', quien);
    return old;
  end if;
end $$;

drop trigger if exists reservas_bu on public.reservas;
create trigger reservas_bu before update on public.reservas for each row execute function public.reservas_trg();
drop trigger if exists reservas_ai on public.reservas;
create trigger reservas_ai after insert on public.reservas for each row execute function public.reservas_trg();
drop trigger if exists reservas_ad on public.reservas;
create trigger reservas_ad after delete on public.reservas for each row execute function public.reservas_trg();

-- ---------- 4. SEGURIDAD DE TABLAS (RLS) ----------

alter table public.reservas_admins    enable row level security;   -- sin políticas: nadie la lee por la API
alter table public.reservas_config    enable row level security;
alter table public.reservas           enable row level security;
alter table public.reservas_historial enable row level security;

drop policy if exists cfg_admin  on public.reservas_config;
create policy cfg_admin  on public.reservas_config    for all    to authenticated using (public.es_admin()) with check (public.es_admin());
drop policy if exists res_admin  on public.reservas;
create policy res_admin  on public.reservas           for all    to authenticated using (public.es_admin()) with check (public.es_admin());
drop policy if exists hist_admin on public.reservas_historial;
create policy hist_admin on public.reservas_historial for select to authenticated using (public.es_admin());

revoke all on public.reservas_admins, public.reservas_config, public.reservas, public.reservas_historial from public, anon, authenticated;
grant select, update on public.reservas_config    to authenticated;
grant select, insert, update, delete on public.reservas to authenticated;
grant select on public.reservas_historial to authenticated;

-- ---------- 5. FUNCIONES PÚBLICAS (lo único que usa la página de reservas) ----------

-- 5.1 Libera las reservas online que no se pagaron a tiempo
create or replace function public.liberar_vencidas() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with u as (
    update public.reservas set estado = 'cancelada', motivo = coalesce(motivo, 'Vencida sin pago')
     where origen = 'online' and estado = 'pendiente' and tipo = 'reserva' and vence is not null and vence < now()
    returning 1)
  select count(*) into n from u;
  return n;
end $$;

-- 5.2 Configuración visible para el público
create or replace function public.config_publica() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'club', jsonb_build_object('nombre', nombre, 'canchas', to_jsonb(canchas), 'datosPago', datos_pago, 'contacto', contacto),
    'reglas', jsonb_build_object('duracionMin', duracion_min, 'anticipacionMax', anticipacion_max,
                                 'horaApertura', to_char(hora_apertura, 'HH24:MI'), 'horaCierre', to_char(hora_cierre, 'HH24:MI'),
                                 'bloquearPasados', bloquear_pasados, 'horasPago', horas_pago, 'precios', precios))
  from public.reservas_config where id = 1
$$;

-- 5.3 Horarios ocupados (sin ningún dato personal)
create or replace function public.disponibilidad(p_desde date, p_hasta date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare z text; r jsonb;
begin
  if p_desde is null or p_hasta is null or p_hasta < p_desde or p_hasta - p_desde > 62 then
    raise exception 'Rango de fechas inválido.';
  end if;
  select zona into z from public.reservas_config where id = 1;
  select jsonb_build_object(
           'ahora', to_char(now() at time zone z, 'YYYY-MM-DD"T"HH24:MI'),
           'ocupados', coalesce(jsonb_agg(jsonb_build_object('cancha', cancha, 'fecha', fecha, 'hora', to_char(hora, 'HH24:MI'), 'duracion', duracion, 'tipo', tipo)), '[]'::jsonb))
    into r
    from public.reservas
   where estado <> 'cancelada' and fecha between p_desde and p_hasta
     and not (origen = 'online' and estado = 'pendiente' and vence is not null and vence < now());
  return r;
end $$;

-- 5.4 Reservar (valida todo en el servidor; el precio lo calcula el servidor)
create or replace function public.reservar(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c public.reservas_config%rowtype;
  v_cancha text := trim(coalesce(p->>'cancha', ''));
  v_fecha date; v_hora time; v_dur int; v_min int; v_ini timestamp; v_ahora timestamp;
  v_nombre text := regexp_replace(trim(coalesce(p->>'nombre', '')), '\s+', ' ', 'g');
  v_rut text := public.res_rut_limpio(p->>'rut');
  v_fono text := trim(coalesce(p->>'fono', ''));
  v_email text := lower(trim(coalesce(p->>'email', '')));
  v_jug jsonb := '[]'::jsonb; j text;
  v_precio int; e jsonb; v_id uuid; v_codigo text; v_vence timestamptz; i int;
begin
  if coalesce(p->>'web', '') <> '' then raise exception 'Solicitud rechazada.'; end if;   -- trampa para robots
  perform public.liberar_vencidas();
  select * into c from public.reservas_config where id = 1;

  begin v_fecha := (p->>'fecha')::date; v_hora := (p->>'hora')::time; v_dur := (p->>'duracion')::int;
  exception when others then raise exception 'Datos del horario inválidos.'; end;
  if v_fecha is null or v_hora is null or v_dur is null then raise exception 'Datos del horario inválidos.'; end if;
  if not (v_cancha = any (c.canchas)) then raise exception 'La cancha indicada no existe.'; end if;
  if v_dur < c.duracion_min or v_dur > 240 or v_dur % 30 <> 0 then raise exception 'Duración no permitida.'; end if;
  v_min := extract(hour from v_hora)::int * 60 + extract(minute from v_hora)::int;
  if v_min % 30 <> 0 then raise exception 'La hora debe ser en punto o y media.'; end if;
  if v_min < extract(hour from c.hora_apertura)::int * 60 + extract(minute from c.hora_apertura)::int
     or v_min + v_dur > extract(hour from c.hora_cierre)::int * 60 + extract(minute from c.hora_cierre)::int then
    raise exception 'El horario está fuera del horario de atención.';
  end if;

  v_ahora := now() at time zone c.zona;
  v_ini := v_fecha + v_hora;
  if c.bloquear_pasados and v_ini <= v_ahora then raise exception 'Ese horario ya pasó.'; end if;
  if v_fecha > v_ahora::date + c.anticipacion_max then
    raise exception 'Solo se puede reservar con % días de anticipación.', c.anticipacion_max;
  end if;

  if length(v_nombre) < 3 or v_nombre !~ '^[A-Za-zÁÉÍÓÚÜÑáéíóúüñ][A-Za-zÁÉÍÓÚÜÑáéíóúüñ'' .-]+$' then raise exception 'Escribe tu nombre completo.'; end if;
  if not public.res_rut_valido(v_rut) then raise exception 'RUT inválido: revisa el dígito verificador.'; end if;
  if not public.res_fono_valido(v_fono) then raise exception 'Teléfono inválido (formato +56 9 1234 5678).'; end if;
  if v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' then raise exception 'Correo inválido.'; end if;
  v_rut := public.res_rut_formato(v_rut);

  if jsonb_typeof(p->'jugadores') = 'array' then
    for j in select left(trim(x), 60) from jsonb_array_elements_text(p->'jugadores') x loop
      if j <> '' and jsonb_array_length(v_jug) < 3 then v_jug := v_jug || to_jsonb(j); end if;
    end loop;
  end if;

  -- Freno al abuso: máximo 2 reservas online pendientes de pago por RUT
  if (select count(*) from public.reservas
       where rut = v_rut and origen = 'online' and estado = 'pendiente' and tipo = 'reserva' and (fecha + hora) > v_ahora) >= 2 then
    raise exception 'Ya tienes 2 reservas pendientes de pago. Págalas o cancélalas para reservar otra.';
  end if;

  v_precio := null;
  for e in select * from jsonb_array_elements(c.precios) loop
    if (e->>'desde')::time <= v_hora and v_hora < (e->>'hasta')::time then v_precio := (e->>'precio')::int; exit; end if;
  end loop;
  if v_precio is null then raise exception 'Ese horario no tiene tarifa definida.'; end if;

  v_vence := case when c.horas_pago > 0 then least(now() + c.horas_pago * interval '1 hour', (v_ini at time zone c.zona)) else null end;

  for i in 1..6 loop
    v_codigo := public.res_codigo();
    begin
      insert into public.reservas (codigo, tipo, origen, cancha, fecha, hora, duracion, estado, precio, nombre, rut, fono, email, jugadores, vence)
      values (v_codigo, 'reserva', 'online', v_cancha, v_fecha, v_hora, v_dur, 'pendiente', v_precio, v_nombre, v_rut, v_fono, v_email, v_jug, v_vence)
      returning id into v_id;
      exit;
    exception
      when exclusion_violation then raise exception 'TURNO_OCUPADO';
      when unique_violation then if i = 6 then raise; end if;
    end;
  end loop;

  return jsonb_build_object('codigo', v_codigo, 'cancha', v_cancha, 'fecha', v_fecha, 'hora', to_char(v_hora, 'HH24:MI'),
                            'duracion', v_dur, 'precio', v_precio, 'estado', 'pendiente', 'vence', v_vence, 'nombre', v_nombre, 'rut', v_rut);
end $$;

-- 5.5 Consultar una reserva (código + RUT)
create or replace function public.consultar_reserva(p_codigo text, p_rut text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.reservas%rowtype;
begin
  perform public.liberar_vencidas();
  select * into r from public.reservas
   where codigo = upper(trim(coalesce(p_codigo, ''))) and tipo = 'reserva'
     and public.res_rut_limpio(rut) = public.res_rut_limpio(p_rut);
  if not found then raise exception 'No encontramos una reserva con ese código y RUT.'; end if;
  return jsonb_build_object('codigo', r.codigo, 'cancha', r.cancha, 'fecha', r.fecha, 'hora', to_char(r.hora, 'HH24:MI'),
                            'duracion', r.duracion, 'precio', r.precio, 'estado', r.estado, 'vence', r.vence, 'nombre', r.nombre);
end $$;

-- 5.6 Cancelar una reserva propia (solo si está pendiente de pago)
create or replace function public.cancelar_reserva(p_codigo text, p_rut text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.reservas%rowtype; z text;
begin
  select zona into z from public.reservas_config where id = 1;
  select * into r from public.reservas
   where codigo = upper(trim(coalesce(p_codigo, ''))) and tipo = 'reserva'
     and public.res_rut_limpio(rut) = public.res_rut_limpio(p_rut) for update;
  if not found then raise exception 'No encontramos una reserva con ese código y RUT.'; end if;
  if r.estado = 'cancelada' then raise exception 'Esta reserva ya estaba cancelada.'; end if;
  if r.estado = 'confirmada' then raise exception 'Esta reserva ya está pagada. Para cambiarla o cancelarla contacta al club.'; end if;
  if (r.fecha + r.hora) <= (now() at time zone z) then raise exception 'Esta reserva ya pasó.'; end if;
  update public.reservas set estado = 'cancelada', motivo = 'Cancelada por el jugador' where id = r.id;
  return jsonb_build_object('ok', true);
end $$;

-- 5.7 ¿Soy administrador? (la página lo usa tras iniciar sesión)
create or replace function public.soy_admin() returns boolean
language sql stable security definer set search_path = public as $$ select public.es_admin() $$;

-- Permisos de ejecución: solo lo necesario
revoke all on function public.liberar_vencidas(), public.config_publica(), public.disponibilidad(date, date), public.reservar(jsonb),
              public.consultar_reserva(text, text), public.cancelar_reserva(text, text), public.soy_admin(), public.es_admin(),
              public.reservas_trg(), public.res_codigo() from public, anon, authenticated;
grant execute on function public.config_publica(), public.disponibilidad(date, date), public.reservar(jsonb),
                          public.consultar_reserva(text, text), public.cancelar_reserva(text, text) to anon, authenticated;
grant execute on function public.liberar_vencidas(), public.soy_admin() to authenticated;
grant execute on function public.es_admin() to authenticated;   -- lo usan las políticas RLS
grant execute on function public.res_rut_limpio(text), public.res_rut_valido(text), public.res_rut_formato(text), public.res_fono_valido(text) to anon, authenticated;

-- ---------- 6. TU CORREO DE ADMINISTRADOR ----------
-- 1) Crea el usuario en Authentication → Users (Add user → Create new user, con "Auto Confirm").
-- 2) Reemplaza el correo y ejecuta esta línea:
-- insert into public.reservas_admins (email) values ('tu-correo@ejemplo.cl') on conflict do nothing;
