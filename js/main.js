/* ============================================
   Fillmore Christian Church - Main JavaScript
   ============================================ */

document.addEventListener('DOMContentLoaded', function() {
  const navToggle = document.querySelector('.nav-toggle');
  const navLinks = document.querySelector('.nav-links');
  const dropdowns = document.querySelectorAll('.nav-dropdown');

  if (navToggle && navLinks) {
    navToggle.addEventListener('click', function() {
      navLinks.classList.toggle('open');
      this.innerHTML = navLinks.classList.contains('open') ? '&times;' : '&#9776;';
    });
  }

  dropdowns.forEach(function(dropdown) {
    const link = dropdown.querySelector('a');
    link.addEventListener('click', function(e) {
      if (window.innerWidth <= 768) {
        e.preventDefault();
        dropdown.classList.toggle('open');
      }
    });
  });

  document.addEventListener('click', function(e) {
    if (navLinks && !e.target.closest('.navbar')) {
      navLinks.classList.remove('open');
      if (navToggle) navToggle.innerHTML = '&#9776;';
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

      window.location.href = 'mailto:' + encodeURIComponent(to) +
        '?subject=' + encodeURIComponent(subject) +
        '&body=' + encodeURIComponent(body);
    });
  });

  document.querySelectorAll('[data-copy-value]').forEach(function(button) {
    button.addEventListener('click', function() {
      const text = button.getAttribute('data-copy-value') || '';
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
        const input = field ? field.querySelector('input') : null;
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
});

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
