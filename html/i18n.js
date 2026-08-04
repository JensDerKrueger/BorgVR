(function () {
  function pickLocale() {
    const language = (navigator.language || navigator.userLanguage || "en").toLowerCase();
    return language.startsWith("de") ? "de" : "en";
  }

  function applyTranslations(translations) {
    const locale = pickLocale();
    const copy = translations[locale] || translations.en || {};

    document.documentElement.lang = locale;

    if (copy.title) {
      document.title = copy.title;
    }

    const metaDescription = document.querySelector('meta[name="description"]');
    if (metaDescription && copy.metaDescription) {
      metaDescription.setAttribute("content", copy.metaDescription);
    }

    document.querySelectorAll("[data-i18n]").forEach((element) => {
      const key = element.getAttribute("data-i18n");
      if (Object.prototype.hasOwnProperty.call(copy, key)) {
        element.textContent = copy[key];
      }
    });

    document.querySelectorAll("[data-i18n-html]").forEach((element) => {
      const key = element.getAttribute("data-i18n-html");
      if (Object.prototype.hasOwnProperty.call(copy, key)) {
        element.innerHTML = copy[key];
      }
    });

    document.querySelectorAll("[data-i18n-attr]").forEach((element) => {
      const mappings = element.getAttribute("data-i18n-attr").split("|");
      mappings.forEach((mapping) => {
        const separatorIndex = mapping.indexOf(":");
        if (separatorIndex === -1) {
          return;
        }

        const attributeName = mapping.slice(0, separatorIndex).trim();
        const key = mapping.slice(separatorIndex + 1).trim();

        if (attributeName && Object.prototype.hasOwnProperty.call(copy, key)) {
          element.setAttribute(attributeName, copy[key]);
        }
      });
    });
  }

  window.BorgVRI18n = {
    applyTranslations: applyTranslations
  };
})();
