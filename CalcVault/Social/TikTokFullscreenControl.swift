import WebKit

/// Adds a user-initiated video-only control to TikTok's main document. It never
/// reads page text, credentials, cookies, URLs, or media bytes, and has no native bridge.
@MainActor
enum TikTokFullscreenControl {
    static let source = #"""
    (() => {
      const hostname = location.hostname.toLowerCase();
      if (hostname !== 'tiktok.com' && !hostname.endsWith('.tiktok.com')) return;

      let control;
      let updateQueued = false;

      function visibleVideo() {
        let selected = null;
        let bestScore = 0;
        for (const video of document.querySelectorAll('video')) {
          const rect = video.getBoundingClientRect();
          const width = Math.max(0, Math.min(rect.right, innerWidth) - Math.max(rect.left, 0));
          const height = Math.max(0, Math.min(rect.bottom, innerHeight) - Math.max(rect.top, 0));
          const area = width * height;
          if (area < 10000 || getComputedStyle(video).visibility === 'hidden') continue;
          const score = area + (!video.paused && !video.ended ? 100000000 : 0);
          if (score > bestScore) {
            selected = video;
            bestScore = score;
          }
        }
        return selected;
      }

      function createControl() {
        const host = document.createElement('div');
        host.id = 'calcvault-video-fullscreen-control';
        host.style.cssText = 'position:fixed;z-index:2147483647;';
        const shadow = host.attachShadow({mode: 'open'});
        const button = document.createElement('button');
        button.type = 'button';
        button.textContent = 'Full screen';
        button.setAttribute('aria-label', 'Full screen current video');
        button.style.cssText = 'background:#222;color:white;border:1px solid #aaa;border-radius:20px;padding:10px 14px;font:14px -apple-system,sans-serif;';
        function showUnavailable() {
          button.textContent = 'Unavailable';
          setTimeout(() => { button.textContent = 'Full screen'; }, 2000);
        }
        button.addEventListener('click', event => {
          event.preventDefault();
          event.stopPropagation();
          const video = visibleVideo();
          if (!video) return;
          try {
            if (typeof video.webkitEnterFullscreen === 'function' && video.webkitSupportsFullscreen !== false) {
              video.webkitEnterFullscreen();
            } else if (typeof video.requestFullscreen === 'function') {
              const result = video.requestFullscreen();
              if (result && typeof result.catch === 'function') result.catch(showUnavailable);
            } else {
              showUnavailable();
            }
          } catch (_) {
            showUnavailable();
          }
        });
        shadow.appendChild(button);
        document.body.appendChild(host);
        control = host;
      }

      function update() {
        updateQueued = false;
        if (!document.body) return;
        const video = visibleVideo();
        if (video && !control) createControl();
        if (!control) return;
        control.style.display = video ? 'block' : 'none';
        if (!video) return;

        const videoRect = video.getBoundingClientRect();
        const controlRect = control.getBoundingClientRect();
        const left = Math.max(8, Math.min(
          videoRect.right - controlRect.width - 12,
          innerWidth - controlRect.width - 8
        ));
        const top = Math.max(8, Math.min(
          videoRect.bottom - controlRect.height - 12,
          innerHeight - controlRect.height - 8
        ));
        control.style.left = `${left}px`;
        control.style.top = `${top}px`;
      }

      function scheduleUpdate() {
        if (updateQueued) return;
        updateQueued = true;
        requestAnimationFrame(update);
      }

      new MutationObserver(scheduleUpdate).observe(document.documentElement, {childList:true, subtree:true});
      document.addEventListener('scroll', scheduleUpdate, true);
      document.addEventListener('loadedmetadata', scheduleUpdate, true);
      window.addEventListener('resize', scheduleUpdate);
      scheduleUpdate();
    })();
    """#

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }
}
