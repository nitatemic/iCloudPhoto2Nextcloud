// iCloudPhoto2Nextcloud — landing page
// Détection de langue identique à l'app : français si le système est en français, anglais sinon.
// Le choix manuel est conservé dans localStorage.

const I18N = {
  fr: {
    menubar_app: "iCloudPhoto2Nextcloud",
    menubar_time: "lun. 17 août 16:32",
    nav_features: "Fonctionnalités",
    nav_how: "Fonctionnement",
    nav_download: "Télécharger",
    hero_badge: "macOS 14+ · Open source · WebDAV",
    hero_title_1: "Vos photos iCloud,",
    hero_title_2: "synchronisées où vous voulez.",
    hero_sub: "Un agent de barre de menus qui sauvegarde automatiquement votre photothèque iCloud sur votre serveur Nextcloud auto-hébergé — vos photos restent chez vous.",
    hero_cta_download: "Télécharger",
    hero_meta_native: "100 % natif macOS",
    mockup_status: "À jour (il y a 2 min)",
    mockup_progress: "Envoi 9 018 / 12 480",
    mockup_thumbs: "Dernières photos synchronisées",
    mockup_force: "Forcer un scan complet",
    mockup_settings: "Réglages & Logs…",
    mockup_quit: "Quitter",
    stat_total: "Total",
    stat_synced: "Synchro",
    stat_pending: "En attente",
    features_title: "Conçu pour être oublié",
    features_sub: "Installé une fois, il travaille en silence dans votre barre de menus.",
    f1_title: "Synchronisation automatique",
    f1_text: "Ajouts, modifications et suppressions détectés en temps réel via PhotoKit. Un scan de suivi garantit qu'aucun événement n'est perdu.",
    f2_title: "Originaux intacts",
    f2_text: "HEIC, Live Photos (photo + vidéo), RAW/ProRAW et vidéos non compressées — envoyés tels quels, sans conversion.",
    f3_title: "Gros fichiers sans effort",
    f3_text: "Au-delà de 10 Mo, upload par morceaux de 5 Mo (WebDAV v2) avec 4 envois simultanés — les grosses vidéos passent sans accroc.",
    f4_title: "Miroir des suppressions",
    f4_text: "Optionnel : une photo supprimée localement l'est aussi sur Nextcloud — même si l'app était fermée au moment de la suppression.",
    f5_title: "Un menu vivant",
    f5_text: "Progression réelle, statistiques, miniatures des dernières photos synchronisées et pause/reprise — tout depuis la barre de menus.",
    f6_title: "Sécurité & confidentialité",
    f6_text: "Mot de passe d'application stocké dans le Keychain local, vérification SHA-256 des mises à jour. Aucune donnée ne transite par un tiers.",
    how_title: "Trois étapes, c'est tout",
    s1_title: "Téléchargez & lancez",
    s1_text: "Choisissez le build adapté à votre Mac et autorisez l'accès à la photothèque.",
    s2_title: "Connectez Nextcloud",
    s2_text: "URL du serveur, nom d'utilisateur et mot de passe d'application — testez la connexion en un clic.",
    s3_title: "Laissez synchroniser",
    s3_text: "La première synchronisation envoie tout ; ensuite, seuls les changements sont traités. Pause possible à tout moment.",
    dl_title: "Télécharger",
    dl_sub: "Builds générés automatiquement par la CI à chaque mise à jour (artefacts GitHub Actions).",
    dl_reco: "Recommandé",
    dl_universal: "Apple Silicon + Intel dans un seul fichier",
    dl_cta: "Ouvrir les artefacts CI",
    dl_note: "Builds non signés : à la première ouverture, faites un clic droit sur l'app → Ouvrir.",
    footer_source: "Code source",
    footer_tagline: "Vos photos, votre serveur, votre tranquillité."
  },
  en: {
    menubar_app: "iCloudPhoto2Nextcloud",
    menubar_time: "Mon Aug 17 16:32",
    nav_features: "Features",
    nav_how: "How it works",
    nav_download: "Download",
    hero_badge: "macOS 14+ · Open source · WebDAV",
    hero_title_1: "Your iCloud photos,",
    hero_title_2: "synced on your terms.",
    hero_sub: "A menu bar agent that automatically backs up your iCloud photo library to your self-hosted Nextcloud server — your photos stay home.",
    hero_cta_download: "Download",
    hero_meta_native: "100% native macOS",
    mockup_status: "Up to date (2 min ago)",
    mockup_progress: "Uploading 9,018 / 12,480",
    mockup_thumbs: "Recently synced photos",
    mockup_force: "Force full scan",
    mockup_settings: "Settings & Logs…",
    mockup_quit: "Quit",
    stat_total: "Total",
    stat_synced: "Synced",
    stat_pending: "Pending",
    features_title: "Built to be forgotten",
    features_sub: "Install it once, and it quietly works from your menu bar.",
    f1_title: "Automatic sync",
    f1_text: "Additions, edits and deletions detected in real time through PhotoKit. A follow-up scan ensures no event is ever missed.",
    f2_title: "Untouched originals",
    f2_text: "HEIC, Live Photos (photo + video), RAW/ProRAW and uncompressed videos — uploaded as-is, with no conversion.",
    f3_title: "Large files, no sweat",
    f3_text: "Above 10 MB, files are uploaded in 5 MB chunks (WebDAV v2) with 4 concurrent transfers — big videos go through effortlessly.",
    f4_title: "Deletion mirror",
    f4_text: "Optional: a photo deleted locally is also deleted on Nextcloud — even if the app was closed when it happened.",
    f5_title: "A living menu",
    f5_text: "Real progress, statistics, thumbnails of recently synced photos, and pause/resume — all from the menu bar.",
    f6_title: "Security & privacy",
    f6_text: "App password stored in the local Keychain, SHA-256 verified updates. No data ever passes through a third party.",
    how_title: "Three steps, that's it",
    s1_title: "Download & launch",
    s1_text: "Pick the build for your Mac and grant access to the photo library.",
    s2_title: "Connect Nextcloud",
    s2_text: "Server URL, username and app password — test the connection with one click.",
    s3_title: "Let it sync",
    s3_text: "The first sync uploads everything; afterwards, only changes are processed. Pause at any time.",
    dl_title: "Download",
    dl_sub: "Builds generated automatically by CI on every update (GitHub Actions artifacts).",
    dl_reco: "Recommended",
    dl_universal: "Apple Silicon + Intel in a single file",
    dl_cta: "Open CI artifacts",
    dl_note: "Unsigned builds: on first launch, right-click the app → Open.",
    footer_source: "Source code",
    footer_tagline: "Your photos, your server, your peace of mind."
  }
};

function detectLang() {
  const saved = localStorage.getItem("lang");
  if (saved === "fr" || saved === "en") return saved;
  return (navigator.language || "en").toLowerCase().startsWith("fr") ? "fr" : "en";
}

function applyLang(lang) {
  const dict = I18N[lang];
  document.documentElement.lang = lang;
  document.title = lang === "fr"
    ? "iCloudPhoto2Nextcloud — Synchronisez vos photos iCloud vers Nextcloud"
    : "iCloudPhoto2Nextcloud — Sync your iCloud photos to Nextcloud";
  document.querySelector('meta[name="description"]').setAttribute("content",
    lang === "fr"
      ? "Agent macOS de barre de menus qui synchronise votre photothèque iCloud vers votre serveur Nextcloud auto-hébergé."
      : "macOS menu bar agent that syncs your iCloud photo library to your self-hosted Nextcloud server.");

  document.querySelectorAll("[data-i18n]").forEach((el) => {
    const key = el.dataset.i18n;
    if (dict[key] !== undefined) el.textContent = dict[key];
  });

  document.getElementById("btn-fr").classList.toggle("active", lang === "fr");
  document.getElementById("btn-en").classList.toggle("active", lang === "en");
}

document.getElementById("btn-fr").addEventListener("click", () => {
  localStorage.setItem("lang", "fr");
  applyLang("fr");
});
document.getElementById("btn-en").addEventListener("click", () => {
  localStorage.setItem("lang", "en");
  applyLang("en");
});

// Reveal on scroll
const observer = new IntersectionObserver(
  (entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add("visible");
        observer.unobserve(entry.target);
      }
    });
  },
  { threshold: 0.12 }
);
document.querySelectorAll(".reveal").forEach((el) => observer.observe(el));

applyLang(detectLang());
