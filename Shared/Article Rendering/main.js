// Here we are making iframes responsive.  Particularly useful for inline Youtube videos.
function wrapFrames() {
	document.querySelectorAll("iframe").forEach(element => {
		if (element.height > 0 || parseInt(element.style.height) > 0)
			return;
		var wrapper = document.createElement("div");
		wrapper.classList.add("iframeWrap");
		element.parentNode.insertBefore(wrapper, element);
		wrapper.appendChild(element);
	});
}

// Strip out color and font styling

function stripStylesFromElement(element, propertiesToStrip) {
	for (name of propertiesToStrip) {
		element.style.removeProperty(name);
	}
}

// Strip inline styles that could harm readability.
function stripStyles() {
	document.getElementsByTagName("body")[0].querySelectorAll("style, link[rel=stylesheet]").forEach(element => element.remove());
	// Removing "background" and "font" will also remove properties that would be reflected in them, e.g., "background-color" and "font-family"
	document.getElementsByTagName("body")[0].querySelectorAll("[style]").forEach(element => stripStylesFromElement(element, ["color", "background", "font", "max-width", "max-height", "position"]));
}

// Constrain the height of iframes whose heights are defined relative to the document body to be at most
// 50% of the viewport width.
function constrainBodyRelativeIframes() {
	let iframes = document.getElementsByTagName("iframe");

	for (iframe of iframes) {
		if (iframe.offsetParent === document.body) {
			let heightAttribute = iframe.style.height;

			if (/%|vw|vh$/i.test(heightAttribute)) {
				iframe.classList.add("nnw-constrained");
			}
		}
	}
}

// Convert all Feedbin proxy images to be used as src, otherwise change image locations to be absolute if not already
function convertImgSrc() {
	document.querySelectorAll("img").forEach(element => {
		if (element.hasAttribute("data-canonical-src")) {
			element.src = element.getAttribute("data-canonical-src")
		} else if (!/^[a-z]+\:\/\//i.test(element.src)) {
			element.src = new URL(element.src, document.baseURI).href;
		}
	});
}

// Wrap tables in an overflow-x: auto; div
function wrapTables() {
	var tables = document.querySelectorAll("div.articleBody table");

	for (table of tables) {
		var wrapper = document.createElement("div");
		wrapper.className = "nnw-overflow";
		table.parentNode.insertBefore(wrapper, table);
		wrapper.appendChild(table);
	}
}

// Add the playsinline attribute to any HTML5 videos that don"t have it.
// Without this attribute videos may autoplay and take over the whole screen
// on an iphone when viewing an article.
function inlineVideos() {
	document.querySelectorAll("video").forEach(element => {
		element.setAttribute("playsinline", true);
		if (!element.classList.contains("nnwAnimatedGIF")) {
			element.setAttribute("controls", true);
			element.removeAttribute("autoplay");
		}
	});
}

// Remove some children (currently just spans) from pre elements to work around a strange clipping issue
var ElementUnwrapper = {
	unwrapSelector: "span",
	unwrapElement: function (element) {
		var parent = element.parentNode;
		var children = Array.from(element.childNodes);

		for (child of children) {
			parent.insertBefore(child, element);
		}

		parent.removeChild(element);
	},
	// `elements` can be a selector string, an element, or a list of elements
	unwrapAppropriateChildren: function (elements) {
		if (typeof elements[Symbol.iterator] !== 'function')
			elements = [elements];
		else if (typeof elements === "string")
			elements = document.querySelectorAll(elements);

		for (element of elements) {
			for (unwrap of element.querySelectorAll(this.unwrapSelector)) {
				this.unwrapElement(unwrap);
			}

			element.normalize()
		}
	}
};

function flattenPreElements() {
	ElementUnwrapper.unwrapAppropriateChildren("div.articleBody td > pre");
}

function reloadArticleImage(imageSrc) {
	var image = document.getElementById("nnwImageIcon");
	image.src = imageSrc + "?" + new Date().getTime();
}

function stopMediaPlayback() {
	document.querySelectorAll("iframe").forEach(element => {
		var iframeSrc = element.src;
		element.src = iframeSrc;
	});

	// We pause all videos that have controls.  Video without controls shouldn't
	// have sound and are actually converted gifs.  Basically if the user can't
	// start the video again, don't stop it.
	document.querySelectorAll("video, audio").forEach(element => {
		if (element.hasAttribute("controls")) {
			element.pause();
		}
	});
}

function error() {
	document.body.innerHTML = "error";
}

// Takes into account absoluting of URLs.
function isLocalFootnote(target) {
	return target.hash.startsWith("#fn") && target.href.indexOf(document.baseURI) === 0;
}

function styleLocalFootnotes() {
	for (elem of document.querySelectorAll("sup > a[href*='#fn'], sup > div > a[href*='#fn']")) {
		if (isLocalFootnote(elem)) {
			elem.classList.add("footnote");
		}
	}
}

// convert <img alt="📰" src="[...]" class="wp-smiley"> to a text node containing 📰
function removeWpSmiley() {
	for (const img of document.querySelectorAll("img.wp-smiley[alt]")) {
		 img.parentNode.replaceChild(document.createTextNode(img.alt), img);
	}
}

var ArticleSpeech = {
	currentTokenID: null,
	tokenCounter: 0,
	tokens: []
};

function ensureArticleSpeechStyle() {
	if (document.getElementById("nnwArticleSpeechStyle")) {
		return;
	}

	const style = document.createElement("style");
	style.id = "nnwArticleSpeechStyle";
	style.textContent = `
		.nnw-speech-token.nnw-speech-current {
			background: rgba(255, 214, 10, 0.36);
			border-radius: 3px;
			box-shadow: 0 0 0 2px rgba(255, 214, 10, 0.22);
			-webkit-box-decoration-break: clone;
			box-decoration-break: clone;
			transition: background-color 80ms linear;
		}

		@media(prefers-color-scheme: dark) {
			.nnw-speech-token.nnw-speech-current {
				background: rgba(255, 214, 10, 0.30);
				box-shadow: 0 0 0 2px rgba(255, 214, 10, 0.18);
			}
		}
	`;
	document.head.appendChild(style);
}

function articleSpeechRoots() {
	return Array.from(document.querySelectorAll(".articleTitle h1, #bodyContainer"))
		.filter(element => element.innerText && element.innerText.trim().length > 0);
}

function articleSpeechElementIsHidden(element) {
	if (!element || element.nodeType !== Node.ELEMENT_NODE) {
		return false;
	}

	if (element.closest("script, style, noscript, iframe, video, audio, pre, code, .externalLink, .headerContainer, .systemMessage, .x-netnewswire-hide")) {
		return true;
	}

	const style = window.getComputedStyle(element);
	return style.display === "none" || style.visibility === "hidden" || style.opacity === "0";
}

function articleSpeechTextNodes(root) {
	const nodes = [];
	const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
		acceptNode: function(node) {
			if (!node.nodeValue || node.nodeValue.trim().length === 0) {
				return NodeFilter.FILTER_REJECT;
			}
			if (articleSpeechElementIsHidden(node.parentElement)) {
				return NodeFilter.FILTER_REJECT;
			}
			return NodeFilter.FILTER_ACCEPT;
		}
	});

	while (walker.nextNode()) {
		nodes.push(walker.currentNode);
	}
	return nodes;
}

function wrapArticleSpeechTextNode(textNode) {
	const text = textNode.nodeValue;
	const tokenPattern = /(\s+|[\p{L}\p{N}]+(?:[\u2019'][\p{L}\p{N}]+)?|[^\s\p{L}\p{N}])/gu;
	const fragment = document.createDocumentFragment();
	let match;

	while ((match = tokenPattern.exec(text)) !== null) {
		const part = match[0];
		if (/^\s+$/.test(part)) {
			fragment.appendChild(document.createTextNode(part));
			continue;
		}

		const span = document.createElement("span");
		const id = "nnw-speech-token-" + ArticleSpeech.tokenCounter++;
		span.className = "nnw-speech-token";
		span.setAttribute("data-nnw-speech-id", id);
		span.textContent = part;
		fragment.appendChild(span);
		ArticleSpeech.tokens.push({ id: id, text: part });
	}

	textNode.parentNode.replaceChild(fragment, textNode);
}

function clearArticleSpeechHighlight() {
	if (ArticleSpeech.currentTokenID) {
		const previous = document.querySelector(`span[data-nnw-speech-id="${CSS.escape(ArticleSpeech.currentTokenID)}"]`);
		if (previous) {
			previous.classList.remove("nnw-speech-current");
		}
		ArticleSpeech.currentTokenID = null;
	}
}

function clearArticleSpeech() {
	clearArticleSpeechHighlight();
	document.querySelectorAll("span.nnw-speech-token").forEach(span => {
		span.parentNode.replaceChild(document.createTextNode(span.textContent), span);
	});
	document.body.normalize();
	ArticleSpeech.tokenCounter = 0;
	ArticleSpeech.tokens = [];
}

function prepareArticleSpeech() {
	clearArticleSpeech();
	ensureArticleSpeechStyle();

	const roots = articleSpeechRoots();
	roots.forEach(root => {
		articleSpeechTextNodes(root).forEach(wrapArticleSpeechTextNode);
	});

	const text = roots
		.map(root => root.innerText.trim())
		.filter(text => text.length > 0)
		.join("\n\n");

	return {
		text: text,
		tokens: ArticleSpeech.tokens
	};
}

function setArticleSpeechHighlight(tokenID, scrollToHighlight = true) {
	clearArticleSpeechHighlight();
	if (!tokenID) {
		return;
	}

	const element = document.querySelector(`span[data-nnw-speech-id="${CSS.escape(tokenID)}"]`);
	if (!element) {
		return;
	}

	element.classList.add("nnw-speech-current");
	ArticleSpeech.currentTokenID = tokenID;

	if (!scrollToHighlight) {
		return;
	}

	const rect = element.getBoundingClientRect();
	const topInset = 88;
	const bottomInset = 120;
	if (rect.top < topInset || rect.bottom > window.innerHeight - bottomInset) {
		element.scrollIntoView({ block: "center", inline: "nearest" });
	}
}

function processPage() {
	wrapFrames();
	wrapTables();
	inlineVideos();
	stripStyles();
	constrainBodyRelativeIframes();
	convertImgSrc();
	flattenPreElements();
	styleLocalFootnotes();
	removeWpSmiley()
	postRenderProcessing();
}

document.addEventListener("DOMContentLoaded", function(event) {
	processPage();
})
