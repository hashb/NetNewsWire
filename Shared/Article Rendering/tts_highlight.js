// tts_highlight.js
// NetNewsWire
//
// JavaScript injected into article WKWebView for TTS word highlighting.

(function() {
    'use strict';

    // Store original HTML so we can restore it
    var _ttsOriginalHTML = null;
    // Track word spans
    var _ttsWordSpans = [];
    // Track currently highlighted word index
    var _ttsCurrentHighlightIndex = -1;

    /**
     * Extracts plain text from the article body.
     * Returns the text content of the #bodyContainer element.
     */
    function ttsGetArticleText() {
        var body = document.getElementById('bodyContainer');
        if (!body) return '';
        return body.innerText || body.textContent || '';
    }

    /**
     * Wraps each word in the article body with <span> elements for highlighting.
     * Each span gets a sequential ID: tts-word-0, tts-word-1, etc.
     */
    function ttsPrepareHighlighting() {
        var body = document.getElementById('bodyContainer');
        if (!body) return 0;

        // Save original HTML for restoration
        _ttsOriginalHTML = body.innerHTML;
        _ttsWordSpans = [];
        _ttsCurrentHighlightIndex = -1;

        var wordIndex = 0;

        function wrapTextNodes(element) {
            var childNodes = Array.prototype.slice.call(element.childNodes);

            for (var i = 0; i < childNodes.length; i++) {
                var node = childNodes[i];

                if (node.nodeType === Node.TEXT_NODE) {
                    var text = node.textContent;
                    if (!text || !text.trim()) continue;

                    // Split text into words and whitespace
                    var parts = text.match(/(\S+|\s+)/g);
                    if (!parts) continue;

                    var fragment = document.createDocumentFragment();
                    for (var j = 0; j < parts.length; j++) {
                        var part = parts[j];
                        if (part.trim()) {
                            // It's a word - wrap in span
                            var span = document.createElement('span');
                            span.id = 'tts-word-' + wordIndex;
                            span.className = 'tts-word';
                            span.textContent = part;
                            fragment.appendChild(span);
                            _ttsWordSpans.push(span);
                            wordIndex++;
                        } else {
                            // It's whitespace - keep as-is
                            fragment.appendChild(document.createTextNode(part));
                        }
                    }

                    node.parentNode.replaceChild(fragment, node);
                } else if (node.nodeType === Node.ELEMENT_NODE) {
                    // Skip script, style, and already-processed elements
                    var tagName = node.tagName.toLowerCase();
                    if (tagName !== 'script' && tagName !== 'style' && tagName !== 'img' &&
                        tagName !== 'video' && tagName !== 'audio' && tagName !== 'iframe') {
                        wrapTextNodes(node);
                    }
                }
            }
        }

        wrapTextNodes(body);
        return wordIndex;
    }

    /**
     * Highlights a specific word by index and scrolls it into view.
     * @param {number} index - The word index to highlight (-1 to clear all)
     */
    function ttsHighlightWord(index) {
        // Remove previous highlight
        if (_ttsCurrentHighlightIndex >= 0 && _ttsCurrentHighlightIndex < _ttsWordSpans.length) {
            _ttsWordSpans[_ttsCurrentHighlightIndex].classList.remove('tts-highlight');
        }

        _ttsCurrentHighlightIndex = index;

        // Add new highlight
        if (index >= 0 && index < _ttsWordSpans.length) {
            var span = _ttsWordSpans[index];
            span.classList.add('tts-highlight');

            // Scroll into view if needed
            var rect = span.getBoundingClientRect();
            var viewHeight = window.innerHeight || document.documentElement.clientHeight;

            if (rect.top < 60 || rect.bottom > viewHeight - 20) {
                span.scrollIntoView({
                    behavior: 'smooth',
                    block: 'center'
                });
            }
        }
    }

    /**
     * Clears all highlighting and restores original HTML.
     */
    function ttsClearHighlighting() {
        var body = document.getElementById('bodyContainer');
        if (body && _ttsOriginalHTML !== null) {
            body.innerHTML = _ttsOriginalHTML;
            _ttsOriginalHTML = null;
            _ttsWordSpans = [];
            _ttsCurrentHighlightIndex = -1;
        }
    }

    // Expose functions globally so they can be called from Swift
    window.ttsGetArticleText = ttsGetArticleText;
    window.ttsPrepareHighlighting = ttsPrepareHighlighting;
    window.ttsHighlightWord = ttsHighlightWord;
    window.ttsClearHighlighting = ttsClearHighlighting;
})();
