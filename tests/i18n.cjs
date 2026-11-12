// Exercise the kit's real substitution and lookup (FoamyI18nText.js, which
// FoamyI18n.qml calls) with catalog data in pure tests.
const I18n = require('../kit/node-loader.cjs').load('FoamyI18nText');
const en = require('../i18n/en.json');
const no = require('../i18n/no.json');
function text(key, language, values) {
  return I18n.translator(language === 'no' || language === 'nb' ? no : en, en).t(key, values);
}
module.exports = { text, no, en, norwegian: no, nb: no };
