(() => {
  const navToggle = document.querySelector('.nav-toggle');
  const navLinks = document.querySelector('#primary-links');

  if (navToggle && navLinks) {
    const closeNavigation = () => {
      navLinks.classList.remove('is-open');
      navToggle.setAttribute('aria-expanded', 'false');
    };

    navToggle.addEventListener('click', () => {
      const willOpen = !navLinks.classList.contains('is-open');
      navLinks.classList.toggle('is-open', willOpen);
      navToggle.setAttribute('aria-expanded', String(willOpen));
    });

    navLinks.addEventListener('click', (event) => {
      if (event.target instanceof HTMLAnchorElement) {
        closeNavigation();
      }
    });

    window.addEventListener('resize', () => {
      if (window.innerWidth > 760) {
        closeNavigation();
      }
    });
  }

  document.querySelectorAll('[data-copy-target]').forEach((button) => {
    button.addEventListener('click', async () => {
      const targetId = button.getAttribute('data-copy-target');
      const target = targetId ? document.getElementById(targetId) : null;
      const text = target?.textContent?.replace(/^PS>\s?/gm, '').trim();

      if (!text) {
        return;
      }

      try {
        await navigator.clipboard.writeText(text);
        const originalLabel = button.textContent;
        button.textContent = 'COPIED';
        button.classList.add('is-copied');
        window.setTimeout(() => {
          button.textContent = originalLabel;
          button.classList.remove('is-copied');
        }, 1800);
      } catch {
        const range = document.createRange();
        range.selectNodeContents(target);
        const selection = window.getSelection();
        selection?.removeAllRanges();
        selection?.addRange(range);
      }
    });
  });
})();
