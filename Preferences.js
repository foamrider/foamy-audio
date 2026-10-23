// Omarchy stores these fields on the foamy.audio bar entry in shell.json.
var fields = [
  { key: "showPercentage", type: "boolean", label: "Show bar percentage", defaultValue: true }
]

function field(key) { return fields.find(function(f) { return f.key === key }) || null }
function valid(key, value) {
  var f = field(key)
  if (!f) return false
  return f.type === "boolean" ? typeof value === "boolean" : typeof value === "string" && f.options.indexOf(value) >= 0
}
function value(settings, key) { var f = field(key); return f ? settings && valid(key, settings[key]) ? settings[key] : f.defaultValue : undefined }

function optionLabel(option) { return {"3":"3%","5":"5%"}[option] || option }
function saveCommand(key, next) {
  if (!valid(key, next)) return []
  // A leading space prevents the shell IPC CLI from treating JSON booleans as its own arguments.
  return ["omarchy-shell", "shell", "setBarWidget", "foamy.audio", key, " " + JSON.stringify(next), "{}"]
}
if (typeof module !== "undefined") module.exports = { fields:fields, field:field, valid:valid, value:value,   optionLabel:optionLabel, saveCommand:saveCommand }
