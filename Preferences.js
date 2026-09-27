// Omarchy stores these fields on the foamy.audio bar entry in shell.json.
var fields = [
  { key: "language", type: "enum", label: "Language", defaultValue: "system", options: ["system", "en", "nb"] },
  { key: "showPercentage", type: "boolean", label: "Show bar percentage", defaultValue: true }
]
var norwegian = {
  "Firewall rules":"Brannmurregler",
  "Verify":"Kontroller",
  "Apply":"Bruk",
  "Checking…":"Kontrollerer…",
  "Required ports are open.":"Nødvendige porter er åpne.",
  "Rules are restricted. Apply to open the ports.":"Reglene er begrenset. Velg Bruk for å åpne portene.",
  "Rules are missing. Apply to open the ports.":"Regler mangler. Velg Bruk for å åpne portene.",
  "Rules conflict. Review UFW rules.":"Regler er i konflikt. Kontroller UFW-reglene.",
  "Authorization cancelled or denied.":"Godkjenning avbrutt eller avslått.",

  "Advanced":"Avansert",
  "Read-only check. Requests administrator authorization.":"Kontrollerer uten å endre regler. Krever administratorgodkjenning.",
  "Add an unrestricted UDP 6001–6002 rule. Requests administrator authorization.":"Legg til en ubegrenset regel for UDP 6001–6002. Krever administratorgodkjenning.",
  "UFW is inactive.":"UFW er inaktiv.",
  "Rules applied. Verify to check.":"Regler lagt til. Velg Kontroller for å sjekke.",
  "Could not apply UFW rules.":"Kunne ikke legge til UFW-reglene.",
  "Could not complete the UFW check.":"Kunne ikke fullføre UFW-kontrollen.",

  "Microphone level unavailable":"Mikrofonnivå er utilgjengelig",
  "AirPlay group":"AirPlay-gruppe",
  "Audio":"Lyd", "Output":"Utgang", "Input":"Inngang", "Apps":"Apper", "Wireless":"Trådløst",
  "Settings":"Innstillinger", "Back":"Tilbake", "Language":"Språk", "System":"System",
  "Show bar percentage":"Vis prosent i linjen",
  "Saving…":"Lagrer…", "Invalid setting.":"Ugyldig innstilling.",
  "Could not save settings.":"Kunne ikke lagre innstillingene.",
  "Mute output":"Demp utgang", "Unmute output":"Slå på utgang", "Mute microphone":"Demp mikrofon",
  "Unmute microphone":"Slå på mikrofon", "Mute all":"Demp alt", "Unmute all":"Slå på all lyd",
  "No output devices":"Ingen utgangsenheter", "No input devices":"Ingen inngangsenheter",
  "No apps playing audio":"Ingen apper spiller lyd", "No AirPlay speakers found":"Fant ingen AirPlay-høyttalere",
  "Looking for speakers":"Søker etter høyttalere", "Returning to local audio":"Bytter til lokal lyd",
  "AirPlay is off":"AirPlay er av", "AirPlay discovery failed":"Søk etter AirPlay-enheter mislyktes",
  "AirPlay helper returned invalid data":"AirPlay-hjelperen returnerte ugyldige data",
  "Could not start AirPlay discovery":"Kunne ikke starte AirPlay-søk", "Could not stop AirPlay":"Kunne ikke stoppe AirPlay",
  "AirPlay support is not installed (pipewire-zeroconf)":"AirPlay-støtte er ikke installert (pipewire-zeroconf)",
  "Could not change output.":"Kunne ikke bytte utgang.", "Could not change input.":"Kunne ikke bytte inngang.",
  "Output change in progress.":"Bytter utgang. Vent litt.", "Input change in progress.":"Bytter inngang. Vent litt.",
  "Volume":"Volum", "Microphone level":"Mikrofonnivå", "Unknown":"Ukjent", "AirPlay speaker":"AirPlay-høyttaler"
}
function field(key) { return fields.find(function(f) { return f.key === key }) || null }
function valid(key, value) {
  var f = field(key)
  if (!f) return false
  return f.type === "boolean" ? typeof value === "boolean" : typeof value === "string" && f.options.indexOf(value) >= 0
}
function value(settings, key) { var f = field(key); return f ? settings && valid(key, settings[key]) ? settings[key] : f.defaultValue : undefined }
function language(mode, locale) { return mode === "en" || mode === "nb" ? mode : /^(nb|nn|no)(_|-|$)/i.test(locale || "") ? "nb" : "en" }
function text(label, lang) { return lang === "nb" ? norwegian[label] || label : label }
function optionLabel(option) { return {system:"System",en:"English",nb:"Norsk bokmål","3":"3%","5":"5%"}[option] || option }
function saveCommand(key, next) {
  if (!valid(key, next)) return []
  // A leading space prevents the shell IPC CLI from treating JSON booleans as its own arguments.
  return ["omarchy-shell", "shell", "setBarWidget", "foamy.audio", key, " " + JSON.stringify(next), "{}"]
}
if (typeof module !== "undefined") module.exports = { fields:fields, field:field, valid:valid, value:value, language:language, text:text, optionLabel:optionLabel, saveCommand:saveCommand }
