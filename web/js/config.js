// Public configuration. The anon/publishable key is designed to be public: it grants nothing by
// itself — every database function checks the signed-in user. Never put a service key here.
export const CONFIG = {
  supabaseUrl: "https://vtbenbngmpwzcqmixtzb.supabase.co",
  supabaseAnonKey: "sb_publishable_Zx1GaORI0HFLO-LlIEQEOg_gcF7O4dQ",
  staffEmailDomain: "staff.factory.invalid", // must equal the Edge Function secret STAFF_EMAIL_DOMAIN
  idleMinutes: 30,                            // automatic sign-out after inactivity (shared phones)
  timeZone: "Africa/Tripoli",
};
