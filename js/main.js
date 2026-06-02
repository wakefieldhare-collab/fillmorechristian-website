/* ============================================
   Fillmore Christian Church - Main JavaScript
   ============================================ */

document.addEventListener('DOMContentLoaded', function() {
  const navToggle = document.querySelector('.nav-toggle');
  const navLinks = document.querySelector('.nav-links');
  const dropdowns = document.querySelectorAll('.nav-dropdown');

  if (navToggle && navLinks) {
    if (!navLinks.id) {
      navLinks.id = 'primary-navigation';
    }
    navToggle.setAttribute('aria-controls', navLinks.id);
    navToggle.setAttribute('aria-expanded', 'false');

    navToggle.addEventListener('click', function() {
      setNavigationOpen(!navLinks.classList.contains('open'));
    });
  }

  dropdowns.forEach(function(dropdown) {
    const link = dropdown.querySelector('a');
    if (!link) return;

    link.setAttribute('aria-haspopup', 'true');
    link.setAttribute('aria-expanded', 'false');

    link.addEventListener('click', function(e) {
      if (window.innerWidth <= 768) {
        e.preventDefault();
        const isOpen = dropdown.classList.toggle('open');
        link.setAttribute('aria-expanded', isOpen ? 'true' : 'false');
      }
    });
  });

  document.addEventListener('click', function(e) {
    if (navLinks && !e.target.closest('.navbar')) {
      setNavigationOpen(false);
    }
  });

  document.addEventListener('keydown', function(e) {
    if (e.key === 'Escape') {
      setNavigationOpen(false);
      closeDropdowns();
      if (navToggle) navToggle.focus();
    }
  });

  window.addEventListener('resize', function() {
    if (window.innerWidth > 768) {
      setNavigationOpen(false);
      closeDropdowns();
    }
  });

  const currentPage = window.location.pathname.split('/').pop() || 'index.html';
  document.querySelectorAll('.nav-links a').forEach(function(link) {
    const href = link.getAttribute('href');
    if (href === currentPage) {
      link.classList.add('active');
    }
  });

  document.querySelectorAll('form[data-mailto]').forEach(function(form) {
    form.addEventListener('submit', function(e) {
      e.preventDefault();
      const to = form.getAttribute('data-mailto');
      const statusId = form.getAttribute('data-status-target');
      const status = statusId ? document.getElementById(statusId) : null;
      const formData = new FormData(form);
      const name = formData.get('name') || formData.get('contact-name') || '';
      const email = formData.get('email') || '';
      const subject = formData.get('subject') || 'Website contact';
      const message = formData.get('message') || '';
      const body = [
        name ? 'Name: ' + name : '',
        email ? 'Email: ' + email : '',
        '',
        message
      ].join('\n');
      const draftText = [
        'To: ' + to,
        'Subject: ' + subject,
        '',
        body
      ].join('\n');

      const fallback = form.querySelector('[data-mailto-fallback]');
      const draft = fallback ? fallback.querySelector('.mailto-draft') : null;
      if (fallback && draft) {
        draft.value = draftText;
        fallback.hidden = false;
      }

      window.location.href = 'mailto:' + encodeURIComponent(to) +
        '?subject=' + encodeURIComponent(subject) +
        '&body=' + encodeURIComponent(body);

      if (status) {
        status.textContent = 'Your email app should now have a draft addressed to church@fillmorechristian.org. If it did not open, copy the message draft below and send it manually.';
      }
    });
  });

  document.querySelectorAll('[data-copy-value], [data-copy-source]').forEach(function(button) {
    button.addEventListener('click', function() {
      const sourceId = button.getAttribute('data-copy-source');
      const source = sourceId ? document.getElementById(sourceId) : null;
      const text = source ? source.value || source.textContent || '' : button.getAttribute('data-copy-value') || '';
      const statusId = button.getAttribute('data-copy-status-target');
      const status = statusId ? document.getElementById(statusId) : null;
      const originalLabel = button.getAttribute('data-copy-label') || button.textContent;
      const successLabel = button.getAttribute('data-copy-label-success') || 'Copied';
      const successMessage = button.getAttribute('data-copy-success') || 'Copied.';
      const fallbackMessage = button.getAttribute('data-copy-fallback') || 'Text selected. Press Ctrl+C to copy it.';
      const failureMessage = button.getAttribute('data-copy-fail') || 'Copy failed. Select the text and copy it manually.';

      copyText(text).then(function() {
        if (status) status.textContent = successMessage;
        button.textContent = successLabel;
        window.setTimeout(function() {
          button.textContent = originalLabel;
        }, 1800);
      }).catch(function() {
        const field = button.closest('.copy-field');
        const input = source || (field ? field.querySelector('input') : null);
        if (input) {
          input.focus();
          input.select();
          if (status) status.textContent = fallbackMessage;
          button.textContent = 'Selected';
          window.setTimeout(function() {
            button.textContent = originalLabel;
          }, 1800);
        } else if (status) {
          status.textContent = failureMessage;
        }
      });
    });
  });

  initializeAudioEnhancements();

  document.addEventListener('play', function(e) {
    if (!e.target || e.target.tagName !== 'AUDIO') return;

    document.querySelectorAll('audio').forEach(function(player) {
      if (player !== e.target && !player.paused) {
        player.pause();
      }
    });
  }, true);
});

const AUDIO_SPEED_STORAGE_KEY = 'fcc-audio-playback-rate';
const AUDIO_SPEED_OPTIONS = ['0.75', '1', '1.25', '1.5', '1.75', '2'];

function initializeAudioEnhancements() {
  enhanceAudioPlayers(document);

  if (typeof MutationObserver === 'function') {
    const observer = new MutationObserver(function(mutations) {
      mutations.forEach(function(mutation) {
        mutation.addedNodes.forEach(function(node) {
          if (!node || node.nodeType !== 1) return;
          enhanceAudioPlayers(node);
        });
      });
    });

    observer.observe(document.body, {
      childList: true,
      subtree: true
    });
  }
}

function enhanceAudioPlayers(scope) {
  const players = [];
  if (scope.tagName === 'AUDIO') {
    players.push(scope);
  }
  if (typeof scope.querySelectorAll === 'function') {
    scope.querySelectorAll('audio').forEach(function(player) {
      players.push(player);
    });
  }

  players.forEach(function(player) {
    if (player.getAttribute('data-audio-enhanced') === 'true') return;

    player.setAttribute('data-audio-enhanced', 'true');
    setPlayerRate(player, getSavedPlaybackRate());
    player.addEventListener('loadedmetadata', function() {
      setPlayerRate(player, getSavedPlaybackRate());
    });

    const controls = document.createElement('div');
    controls.className = 'audio-tools';
    controls.setAttribute('data-audio-speed-control', 'true');

    const label = document.createElement('label');
    label.className = 'audio-speed-label';
    label.textContent = 'Speed';

    const select = document.createElement('select');
    select.className = 'audio-speed-select';
    select.setAttribute('aria-label', 'Audio playback speed');

    AUDIO_SPEED_OPTIONS.forEach(function(rate) {
      const option = document.createElement('option');
      option.value = rate;
      option.textContent = rate + 'x';
      select.appendChild(option);
    });

    select.value = getSavedPlaybackRate();
    select.addEventListener('change', function() {
      const rate = normalizePlaybackRate(select.value);
      savePlaybackRate(rate);
      document.querySelectorAll('audio').forEach(function(audio) {
        setPlayerRate(audio, rate);
      });
      document.querySelectorAll('.audio-speed-select').forEach(function(otherSelect) {
        otherSelect.value = rate;
      });
    });

    controls.appendChild(label);
    controls.appendChild(select);
    player.insertAdjacentElement('afterend', controls);
  });
}

function getSavedPlaybackRate() {
  try {
    return normalizePlaybackRate(window.localStorage.getItem(AUDIO_SPEED_STORAGE_KEY) || '1');
  } catch (err) {
    return '1';
  }
}

function savePlaybackRate(rate) {
  try {
    window.localStorage.setItem(AUDIO_SPEED_STORAGE_KEY, normalizePlaybackRate(rate));
  } catch (err) {}
}

function normalizePlaybackRate(rate) {
  const normalized = String(rate || '1');
  return AUDIO_SPEED_OPTIONS.indexOf(normalized) !== -1 ? normalized : '1';
}

function setPlayerRate(player, rate) {
  try {
    player.playbackRate = Number(normalizePlaybackRate(rate));
  } catch (err) {}
}

function setNavigationOpen(isOpen) {
  const navToggle = document.querySelector('.nav-toggle');
  const navLinks = document.querySelector('.nav-links');
  if (!navToggle || !navLinks) return;

  navLinks.classList.toggle('open', isOpen);
  navToggle.setAttribute('aria-expanded', isOpen ? 'true' : 'false');
  navToggle.innerHTML = isOpen ? '&times;' : '&#9776;';

  if (!isOpen) {
    closeDropdowns();
  }
}

function closeDropdowns() {
  document.querySelectorAll('.nav-dropdown').forEach(function(dropdown) {
    dropdown.classList.remove('open');
    const link = dropdown.querySelector('a');
    if (link) {
      link.setAttribute('aria-expanded', 'false');
    }
  });
}

function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) {
    return navigator.clipboard.writeText(text).catch(function() {
      return fallbackCopyText(text);
    });
  }

  return fallbackCopyText(text);
}

function fallbackCopyText(text) {
  return new Promise(function(resolve, reject) {
    const input = document.createElement('textarea');
    input.value = text;
    input.setAttribute('readonly', '');
    input.style.position = 'fixed';
    input.style.top = '0';
    input.style.left = '0';
    input.style.opacity = '0';
    document.body.appendChild(input);
    input.focus();
    input.select();

    try {
      if (document.execCommand('copy')) {
        resolve();
      } else {
        reject(new Error('copy command failed'));
      }
    } catch (err) {
      reject(err);
    } finally {
      document.body.removeChild(input);
    }
  });
}
