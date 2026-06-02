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

  document.addEventListener('play', function(e) {
    if (!e.target || e.target.tagName !== 'AUDIO') return;

    document.querySelectorAll('audio').forEach(function(player) {
      if (player !== e.target && !player.paused) {
        player.pause();
      }
    });
  }, true);
});

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
