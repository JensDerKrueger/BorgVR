(function () {
  function pickLocale() {
    const requested = new URLSearchParams(window.location.search).get("lang");
    if (requested === "en" || requested === "de") return requested;
    const language = (navigator.language || navigator.userLanguage || "en").toLowerCase();
    return language.startsWith("de") ? "de" : "en";
  }

  function applyTranslations(translations) {
    const locale = pickLocale();
    const copy = translations[locale] || translations.en || {};

    document.documentElement.lang = locale;

    document.querySelectorAll("[data-language]").forEach((link) => {
      link.setAttribute("aria-current", String(link.getAttribute("data-language") === locale));
    });

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

    if (locale === "de") {
      document.querySelectorAll("[data-de]").forEach((element) => {
        const translation = element.getAttribute("data-de");
        if (translation.includes("<")) {
          element.innerHTML = translation;
        } else {
          element.textContent = translation;
        }
      });

      document.querySelectorAll("[data-de-html]").forEach((element) => {
        element.innerHTML = element.getAttribute("data-de-html");
      });

      document.querySelectorAll("[data-de-attr]").forEach((element) => {
        const mappings = element.getAttribute("data-de-attr").split("|");
        mappings.forEach((mapping) => {
          const separatorIndex = mapping.indexOf(":");
          if (separatorIndex === -1) {
            return;
          }

          const attributeName = mapping.slice(0, separatorIndex).trim();
          const value = mapping.slice(separatorIndex + 1).trim();
          if (attributeName) {
            element.setAttribute(attributeName, value);
          }
        });
      });
    }

    // Run after translated HTML has inserted its links, including in offline help.
    if (new URLSearchParams(window.location.search).has("lang")) {
      document.querySelectorAll('a[href]').forEach((link) => {
        const href = link.getAttribute("href");
        if (!href || href.startsWith("#") || link.hasAttribute("data-language")) return;
        const destination = new URL(href, window.location.href);
        if (destination.origin === window.location.origin && destination.pathname.endsWith(".html")) {
          destination.searchParams.set("lang", locale);
          link.setAttribute("href", destination.href);
        }
      });
    }
  }

  window.BorgVRI18n = {
    applyTranslations: applyTranslations
  };
})();
