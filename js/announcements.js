(function () {
  "use strict";

  const lists = Array.from(document.querySelectorAll("[data-announcements-list]"));
  if (lists.length === 0) {
    return;
  }

  function formatServiceDate(value) {
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value || "");
    if (!match) {
      return "this Sunday";
    }

    const date = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]), 12));
    return new Intl.DateTimeFormat("en-US", {
      weekday: "long",
      month: "long",
      day: "numeric",
      year: "numeric",
      timeZone: "UTC"
    }).format(date);
  }

  function createAnnouncementCard(announcement) {
    const article = document.createElement("article");
    article.className = "announcement-card";

    if (announcement.when) {
      const when = document.createElement("p");
      when.className = "announcement-when";
      when.textContent = announcement.when;
      article.appendChild(when);
    }

    const title = document.createElement("h3");
    title.textContent = announcement.title;
    article.appendChild(title);

    if (announcement.details) {
      const details = document.createElement("p");
      details.textContent = announcement.details;
      article.appendChild(details);
    }

    if (announcement.location) {
      const location = document.createElement("p");
      location.className = "announcement-location";
      location.textContent = announcement.location;
      article.appendChild(location);
    }

    if (announcement.url) {
      const link = document.createElement("a");
      link.className = "announcement-link";
      link.href = announcement.url;
      link.target = "_blank";
      link.rel = "noopener";
      link.textContent = announcement.link_label || "Learn more";
      article.appendChild(link);
    }

    return article;
  }

  function render(data) {
    const announcements = Array.isArray(data.announcements) ? data.announcements : [];
    const serviceDate = formatServiceDate(data.service_date);

    document.querySelectorAll("[data-announcements-service-date]").forEach(function (element) {
      element.textContent = serviceDate;
    });

    document.querySelectorAll("[data-announcements-updated]").forEach(function (element) {
      element.textContent = data.updated_at ? "Updated " + data.updated_at : "Updated weekly";
    });

    lists.forEach(function (list) {
      const parsedLimit = Number.parseInt(list.dataset.announcementsLimit || "", 10);
      const visible = Number.isFinite(parsedLimit) ? announcements.slice(0, parsedLimit) : announcements;
      list.replaceChildren();

      if (visible.length === 0) {
        const empty = document.createElement("p");
        empty.className = "announcements-empty";
        empty.textContent = "There are no current announcements. Please check back after Sunday worship.";
        list.appendChild(empty);
        return;
      }

      visible.forEach(function (announcement) {
        list.appendChild(createAnnouncementCard(announcement));
      });
    });
  }

  function showError() {
    lists.forEach(function (list) {
      const loading = list.querySelector(".announcements-loading");
      if (loading) {
        loading.remove();
      }
      const existing = list.querySelector("[data-announcements-fallback]");
      if (existing) {
        existing.hidden = false;
      }
    });
  }

  fetch("announcements.json", { cache: "no-store" })
    .then(function (response) {
      if (!response.ok) {
        throw new Error("Announcement data could not be loaded.");
      }
      return response.json();
    })
    .then(render)
    .catch(showError);
})();
