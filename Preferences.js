// Settings schema for the foamy.audio bar entry (mirrors manifest.json
// barWidget.schema); validation and saving are kit/FoamyPrefs.js.
var fields = [
  { key: "showPercentage", type: "boolean", label: "Show percentage in the bar", defaultValue: true }
]
if (typeof module !== "undefined") module.exports = { fields: fields }
