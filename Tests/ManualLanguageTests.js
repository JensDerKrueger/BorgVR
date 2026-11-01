const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../html/i18n.js'), 'utf8');

function element(attributes) {
  return {
    attributes: { ...attributes },
    getAttribute(name) { return this.attributes[name]; },
    hasAttribute(name) { return Object.hasOwn(this.attributes, name); },
    setAttribute(name, value) { this.attributes[name] = value; }
  };
}

for (const base of ['file:///manual/interface.html', 'https://example.com/manual/interface.html']) {
  for (const [query, browserLanguage, expected] of [
    ['', 'de-DE', 'de'], ['', 'fr-FR', 'en'],
    ['?lang=en', 'de-DE', 'en'], ['?lang=de', 'en-US', 'de'],
    ['?lang=invalid', 'de-DE', 'de']
  ]) {
    const location = new URL(base + query);
    const english = element({ 'data-language': 'en', href: '?lang=en' });
    const german = element({ 'data-language': 'de', href: '?lang=de' });
    const local = element({ href: './macos.html#controls' });
    const hash = element({ href: '#start' });
    const external = element({ href: 'https://elsewhere.example/guide.html' });
    const image = element({ href: './screenshots/en/macos-start.webp', 'data-de-attr': 'href:./screenshots/macos-start.webp' });
    const screenshot = element({ src: './screenshots/en/macos-start.webp', alt: 'Start screen', 'data-de-attr': 'src:./screenshots/macos-start.webp|alt:Startbildschirm' });
    const inserted = element({ href: './ios.html' });
    const translated = element({ 'data-de': '<a href="./ios.html">iOS-Anleitung</a>' });
    let insertedLink = false;
    Object.defineProperty(translated, 'innerHTML', { set() { insertedLink = true; } });
    const links = [english, german, local, hash, external, image];
    const document = {
      documentElement: {},
      querySelector() { return null; },
      querySelectorAll(selector) {
        if (selector === '[data-language]') return [english, german];
        if (selector === '[data-de]') return [translated];
        if (selector === '[data-de-attr]') return [image, screenshot];
        if (selector === 'a[href]') return insertedLink ? [...links, inserted] : links;
        return [];
      }
    };
    const window = { location };
    vm.runInNewContext(source, { window, document, navigator: { language: browserLanguage }, URL, URLSearchParams });
    window.BorgVRI18n.applyTranslations({ en: { title: 'Guide' }, de: { title: 'Anleitung' } });
    assert.equal(document.documentElement.lang, expected);
    assert.equal(document.title, expected === 'de' ? 'Anleitung' : 'Guide');
    assert.equal((expected === 'de' ? german : english).getAttribute('aria-current'), 'true');
    assert.equal(hash.getAttribute('href'), '#start');
    assert.equal(external.getAttribute('href'), 'https://elsewhere.example/guide.html');
    const screenshotPath = expected === 'de' ? './screenshots/macos-start.webp' : './screenshots/en/macos-start.webp';
    assert.equal(image.getAttribute('href'), screenshotPath);
    assert.equal(screenshot.getAttribute('src'), screenshotPath);
    assert.equal(screenshot.getAttribute('alt'), expected === 'de' ? 'Startbildschirm' : 'Start screen');
    assert.equal(english.getAttribute('href'), '?lang=en');
    if (query) {
      assert.equal(new URL(local.getAttribute('href')).searchParams.get('lang'), expected);
      assert.equal(new URL(local.getAttribute('href')).hash, '#controls');
      if (expected === 'de') {
        assert.equal(new URL(inserted.getAttribute('href')).searchParams.get('lang'), 'de');
      }
    } else {
      assert.equal(local.getAttribute('href'), './macos.html#controls');
    }
  }
}
console.log('Manual language tests passed (English/German, web/offline, translated links).');
