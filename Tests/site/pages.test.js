// 사이트 페이지의 구조 검사: 두 언어 짝·목차·이미지 대체 텍스트·앵커·외부 링크 형식.
// 외부 링크는 네트워크로 확인하지 않는다(테스트가 인터넷에 의존하지 않도록). 형식과 저장소 주소만 본다.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const site = path.join(__dirname, "../../site");
const root = path.join(__dirname, "../..");
const read = (f) => fs.readFileSync(path.join(site, f), "utf8");
const pages = fs.readdirSync(site).filter((f) => f.endsWith(".html"));
const pairs = [
  ["index.html", "ko.html"],
  ["manual.html", "manual-ko.html"],
];
const resolvePage = (ref) => (ref === "./" || ref === "" ? "index.html" : ref);

const imgs = (html) => [...html.matchAll(/<img\b[^>]*>/g)].map((m) => m[0]);
const attr = (tag, name) => {
  const m = tag.match(new RegExp(`\\s${name}="([^"]*)"`));
  return m ? m[1] : undefined;
};
const ids = (html) => [...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]);
const hangul = /\p{Script=Hangul}/u;

/** 다른 페이지를 가리키는 page.html#id 링크 중 대상 페이지에 그 id가 없는 것 */
function brokenCrossPageAnchors(html, idsOf) {
  const broken = [];
  for (const m of html.matchAll(/href="([^"#:]*\.html|\.\/)#([^"]+)"/g)) {
    const target = resolvePage(m[1]);
    if (!idsOf(target).has(m[2])) broken.push(`${m[1]}#${m[2]}`);
  }
  return broken;
}

test("no page repeats an id", () => {
  for (const page of pages) {
    const all = ids(read(page));
    const dup = all.filter((id, i) => all.indexOf(id) !== i);
    assert.deepEqual(dup, [], page);
  }
});

test("links to another page's section point to an existing id", () => {
  const idsOf = (p) => new Set(fs.existsSync(path.join(site, p)) ? ids(read(p)) : []);
  // 검사기 자체가 깨진 링크를 잡는지 먼저 확인한다(지금 사이트에는 이런 링크가 없을 수 있다).
  assert.deepEqual(brokenCrossPageAnchors('<a href="manual.html#install"></a><a href="manual.html#nope"></a>', idsOf), ["manual.html#nope"]);
  for (const page of pages) {
    assert.deepEqual(brokenCrossPageAnchors(read(page), idsOf), [], page);
  }
});

for (const page of ["manual.html", "manual-ko.html"]) {
  test(`${page}: the table of contents lists every section in order`, () => {
    const html = read(page);
    const toc = html.match(/<nav class="toc"[\s\S]*?<\/nav>/);
    assert.ok(toc, "목차가 없습니다");
    const entries = [...toc[0].matchAll(/href="#([^"]+)"/g)].map((m) => m[1]);
    const sections = [...html.matchAll(/<h2 id="([^"]+)"/g)].map((m) => m[1]);
    assert.deepEqual(entries, sections);
  });
}

test("both manuals have the same subsections and images in each section", () => {
  const shape = (f) =>
    read(f)
      .split(/<h2 id=/)
      .slice(1)
      .map((s) => ({ id: s.match(/^"([^"]+)"/)[1], h3: (s.match(/<h3\b/g) || []).length, img: imgs(s).length }));
  assert.deepEqual(shape("manual-ko.html"), shape("manual.html"));
});

for (const [en, ko] of pairs) {
  test(`${en} and ${ko} declare their language and link to each other`, () => {
    for (const [page, lang, other, otherLang] of [
      [en, "en", ko, "ko"],
      [ko, "ko", en, "en"],
    ]) {
      const html = read(page);
      assert.match(html, new RegExp(`<html lang="${lang}"`), `${page}: <html lang>`);
      const alternate = html.match(/<link rel="alternate" hreflang="([^"]+)" href="([^"]+)">/);
      assert.ok(alternate, `${page}: rel=alternate 없음`);
      assert.equal(alternate[1], otherLang, `${page}: hreflang`);
      assert.equal(resolvePage(alternate[2]), other, `${page}: alternate 대상`);
      const switcher = html.match(new RegExp(`<a href="([^"]+)" hreflang="${otherLang}" lang="${otherLang}">`));
      assert.ok(switcher, `${page}: 언어 전환 링크 없음`);
      assert.equal(resolvePage(switcher[1]), other, `${page}: 언어 전환 대상`);
    }
  });
}

test("every image has alt text; content images describe themselves in the page language", () => {
  for (const page of pages) {
    const korean = page === "ko.html" || page.endsWith("-ko.html");
    for (const tag of imgs(read(page))) {
      const alt = attr(tag, "alt");
      assert.notEqual(alt, undefined, `${page}: alt 없음 ${tag}`);
      const src = attr(tag, "src");
      // 아이콘 옆 장식용 favicon만 빈 alt를 허용한다
      if (src === "assets/favicon.png") continue;
      assert.ok(alt.trim().length > 0, `${page}: 빈 alt ${src}`);
      if (korean) assert.match(alt, hangul, `${page}: 한국어 alt ${src}`);
      else assert.doesNotMatch(alt, /\p{Script=Hangul}{2,}/u, `${page}: 영어 alt ${src}`);
    }
  }
});

test("each manual shows settings screenshots in its own language", () => {
  const screens = (f) => imgs(read(f)).map((t) => attr(t, "src")).filter((s) => s.startsWith("assets/screens/") && s.split("/").length > 3);
  const en = screens("manual.html");
  const ko = screens("manual-ko.html");
  assert.ok(en.length > 0);
  assert.ok(en.every((s) => s.startsWith("assets/screens/en/")), en.join(", "));
  assert.ok(ko.every((s) => s.startsWith("assets/screens/ko/")), ko.join(", "));
  assert.deepEqual(ko.map((s) => path.basename(s)), en.map((s) => path.basename(s)));
});

test("image width/height match the PNG's aspect ratio and never upscale it", () => {
  for (const page of pages) {
    for (const tag of imgs(read(page))) {
      const src = attr(tag, "src");
      const png = fs.readFileSync(path.join(site, src));
      assert.equal(png.toString("latin1", 12, 16), "IHDR", `${src}: PNG가 아닙니다`);
      const [pw, ph] = [png.readUInt32BE(16), png.readUInt32BE(20)];
      const [w, h] = [Number(attr(tag, "width")), Number(attr(tag, "height"))];
      assert.ok(w > 0 && h > 0, `${page}: width/height 없음 ${src}`);
      assert.ok(Math.abs(w / h - pw / ph) < 0.01, `${page}: ${src} ${w}x${h} vs ${pw}x${ph}`);
      assert.ok(w <= pw && h <= ph, `${page}: ${src}를 늘려서 보여 줍니다`);
    }
  }
});

test("external links use https and point to this project's GitHub repository", () => {
  for (const page of pages) {
    const html = read(page);
    for (const m of html.matchAll(/(?:href|src)="([a-z][a-z0-9+.-]*:[^"]*)"/gi)) {
      const url = m[1];
      if (url.startsWith("mailto:")) continue;
      assert.match(url, /^https:\/\//, `${page}: ${url}`);
      if (url.includes("github.com/")) assert.match(url, /^https:\/\/github\.com\/sejoung\/KeyHue(\/|$|#)/, `${page}: ${url}`);
    }
  }
});

test("download links use the stable asset name that package.sh publishes", () => {
  const stable = "https://github.com/sejoung/KeyHue/releases/latest/download/KeyHue.zip";
  for (const page of ["index.html", "ko.html", "manual.html", "manual-ko.html"]) {
    const downloads = [...read(page).matchAll(/href="([^"]*\/releases\/[^"]*download[^"]*)"/g)].map((m) => m[1]);
    assert.ok(downloads.length > 0, `${page}: 다운로드 링크 없음`);
    for (const url of downloads) assert.equal(url, stable, page);
  }
  const packageScript = fs.readFileSync(path.join(root, "scripts/package.sh"), "utf8");
  assert.match(packageScript, /cp "\$ZIP" "\$DIST\/KeyHue\.zip"/, "package.sh가 고정 이름 사본을 만들지 않습니다");
  assert.match(packageScript, /ZIP="\$DIST\/\$PRODUCT-\$VERSION\.zip"/);
  const siteScript = read("assets/site.js");
  assert.match(siteScript, /`KeyHue-\$\{version\}\.zip`/, "site.js가 찾는 버전별 파일 이름");
});
