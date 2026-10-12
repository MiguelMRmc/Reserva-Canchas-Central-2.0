/* Configuración de la conexión en línea.
   1) En Supabase: Project Settings → API.
   2) Copia "Project URL" y la clave "anon public" (NUNCA la "service_role").
   La clave anon es pública por diseño: la seguridad la dan las reglas de la base de datos (reservas.sql).
   Si dejas estos valores vacíos, la página funciona sin conexión (solo en ese navegador). */
window.RESERVAS_CONFIG = {
  SUPABASE_URL: 'https://rlqkiqfweynwecnrhdzf.supabase.co/rest/v1/',        // ej.: 'https://abcdefghijk.supabase.co'
  SUPABASE_ANON_KEY: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJscWtpcWZ3ZXlud2VjbnJoZHpmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE4MTE3MTksImV4cCI6MjEwNzM4NzcxOX0.zxmH34_fHgblaORb-GAfnRPJ2IAO8yOP57yblzADr_8'    // ej.: 'eyJhbGciOi...'
};
