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
});
