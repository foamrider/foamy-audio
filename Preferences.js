// Omarchy stores these fields on the foamy.audio bar entry in shell.json.
var fields = [
  { key: "language", type: "enum", label: "Language", defaultValue: "system", options: ["system", "en", "nb"] },
  { key: "showPercentage", type: "boolean", label: "Show bar percentage", defaultValue: true },
  { key: "scrollVolumeStep", type: "enum", label: "Volume scroll step", defaultValue: "3", options: ["3", "5"] }
]
var norwegian = {
  "Microphone level unavailable":"Mikrofonnivå er utilgjengelig",
  "Audio":"Lyd", "Output":"Utgang", "Input":"Inngang", "Apps":"Apper", "Wireless":"Trådløst",
  "Settings":"Innstillinger", "Back":"Tilbake", "Language":"Språk", "System":"System",
  "Show bar percentage":"Vis prosent i linjen", "Volume scroll step":"Volumtrinn ved rulling",
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
