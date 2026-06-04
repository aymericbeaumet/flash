import Foundation

/// Legacy synthetic fixture HTML used by older focused Firefox harness
/// helpers. The main browser integration corpus now lives under
/// `Tests/BrowserSnapshots` and is loaded through `BrowserFixtureCatalog`.
///
/// The HTML is structured as discrete `<section>`s so each regression
/// mode (undermatch, overmatch, hidden-subtree exclusion) has its own
/// bucket. Element counts intentionally include some redundancy
/// (5 buttons not 1) so a regression that drops half the matches is
/// still detectable.
public enum FirefoxFixture {
  /// Number of each kind of element in the fixture. Update both this
  /// table and the corresponding HTML section in lockstep.
  public struct Counts {
    // Must-hint controls.
    public static let links = 5  // <a href>
    public static let imgLinks = 3  // <a href><img></a> — img must NOT double-hint
    public static let buttons = 5  // <button>
    public static let submitInputs = 1  // <input type=submit>
    public static let textInputs = 2  // <input type=text>
    public static let emailInputs = 2  // <input type=email>
    public static let passwordInputs = 1  // <input type=password>
    public static let numberInputs = 1  // <input type=number>
    public static let telInputs = 1  // <input type=tel>
    public static let urlInputs = 1  // <input type=url>
    public static let searchInputs = 1  // <input type=search>
    public static let checkboxes = 2  // <input type=checkbox>
    public static let radios = 3  // <input type=radio> (same group)
    public static let selects = 1  // <select>
    public static let textareas = 1  // <textarea>
    public static let detailsBlocks = 1  // <details><summary>
    public static let contentEditables = 1  // <div contenteditable=true>
    public static let roleButtonDivs = 1  // <div role=button tabindex=0>
    public static let roleLinkDivs = 1  // <div role=link tabindex=0>

    // Must-not-hint elements.
    public static let headings = 5  // <h1>/<h2>/<h3>
    public static let paragraphs = 5  // <p>
    public static let plainDivs = 5  // <div> (no role, no click)
    public static let plainImages = 3  // <img> standalone, no click handler

    // Hidden / disabled sentinels. None of these should contribute to
    // ANY role count.
    public static let disabledButtons = 5  // <button disabled>
    public static let disabledInputs = 5  // <input disabled>
    public static let ariaHiddenButtons = 5  // <button> inside aria-hidden subtree
    public static let ariaHiddenInputs = 5  // <input> inside aria-hidden subtree
    public static let displayNoneButtons = 5  // <button> inside display:none subtree
    public static let offscreenButtons = 700  // visible only after scrolling

    // Per-role aggregates derived from the section counts. Kept here so
    // the assertion bodies don't sprout their own ad-hoc arithmetic.
    public static let expectedLinks = links + imgLinks
    public static let expectedButtons = buttons + submitInputs
    public static let expectedTextFields =
      textInputs + emailInputs + passwordInputs + numberInputs + telInputs + urlInputs
  }

  /// Roles the AccessibilityProvider promises to never produce as a
  /// hint target. AXHeading and AXStaticText are page structure — a
  /// regression that lets them through would dump a hint on every
  /// sentence. AXGroup / AXScrollArea / AXSplitter / AXWebArea are
  /// layout containers; hinting them would land in the middle of a
  /// huge region instead of on a specific control.
  public static let forbiddenRoles: Set<String> = [
    "AXHeading",
    "AXStaticText",
    "AXGroup",
    "AXGenericElement",
    "AXScrollArea",
    "AXSplitter",
    "AXWebArea",
    "AXSection",
    "AXParagraph",
    "AXDocument",
    "AXOutline",
    "AXList",
    "AXListItem",
  ]

  public static let bundleID = "org.mozilla.firefox"
  public static let appPath = "/Applications/Firefox.app"

  /// Encoded data: URL ready to hand to NSWorkspace.open.
  public static func dataURL() -> URL {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "#&=+")
    let encoded = html.addingPercentEncoding(withAllowedCharacters: allowed)!
    return URL(string: "data:text/html;charset=utf-8,\(encoded)")!
  }

  public static let html: String = {
    var html = """
      <!DOCTYPE html>
      <html><head>
      <title>FlashE2E</title>
      <style>
        body { font: 16px/1.4 -apple-system; padding: 16px; }
        section { border: 1px solid #ccc; padding: 12px; margin: 12px 0; }
        h2 { margin: 0 0 8px; font-size: 14px; color: #666; }
        button, input, select, textarea { margin: 4px; }
        img { width: 32px; height: 32px; background: #ddd; display: inline-block; }
        .offscreen-flood { margin-top: 1400px; }
        .offscreen-flood-grid {
          display: grid;
          grid-template-columns: repeat(4, max-content);
          gap: 8px;
          align-items: start;
        }
        .offscreen-flood-grid button {
          margin: 0;
          min-width: 64px;
          padding: 2px 4px;
        }
      </style>
      </head><body>
      <section id="links"><h2>links</h2>
      """
    for i in 1...Counts.links {
      html += "<a href=\"#l\(i)\">link-\(i)</a> "
    }
    html += "</section><section id=\"img-links\"><h2>image links</h2>"
    for i in 1...Counts.imgLinks {
      html += "<a href=\"#il\(i)\"><img alt=\"il-\(i)\"></a> "
    }
    html += "</section><section id=\"buttons\"><h2>buttons</h2>"
    for i in 1...Counts.buttons {
      html += "<button>btn-\(i)</button> "
    }
    for i in 1...Counts.submitInputs {
      html += "<input type=\"submit\" value=\"submit-\(i)\"> "
    }
    html += "</section><section id=\"inputs\"><h2>inputs</h2>"
    for i in 1...Counts.textInputs {
      html += "<input type=\"text\" placeholder=\"text-\(i)\"> "
    }
    for i in 1...Counts.emailInputs {
      html += "<input type=\"email\" placeholder=\"email-\(i)\"> "
    }
    for i in 1...Counts.passwordInputs {
      html += "<input type=\"password\" placeholder=\"pw-\(i)\"> "
    }
    for i in 1...Counts.numberInputs {
      html += "<input type=\"number\" placeholder=\"num-\(i)\"> "
    }
    for i in 1...Counts.telInputs {
      html += "<input type=\"tel\" placeholder=\"tel-\(i)\"> "
    }
    for i in 1...Counts.urlInputs {
      html += "<input type=\"url\" placeholder=\"url-\(i)\"> "
    }
    for i in 1...Counts.searchInputs {
      html += "<input type=\"search\" placeholder=\"search-\(i)\"> "
    }
    html += "</section><section id=\"checks-radios\"><h2>checks + radios</h2>"
    for i in 1...Counts.checkboxes {
      html += "<label><input type=\"checkbox\"> cb-\(i)</label> "
    }
    for i in 1...Counts.radios {
      html += "<label><input type=\"radio\" name=\"r\"> r-\(i)</label> "
    }
    html += "</section><section id=\"selects\"><h2>selects + textareas</h2>"
    for i in 1...Counts.selects {
      html += "<select><option>s-\(i)-a</option><option>s-\(i)-b</option></select> "
    }
    for i in 1...Counts.textareas {
      html += "<textarea>ta-\(i)</textarea> "
    }
    html += "</section><section id=\"native-disclosure\"><h2>native disclosure</h2>"
    for i in 1...Counts.detailsBlocks {
      html += "<details><summary>summary-\(i)</summary><p>body-\(i)</p></details> "
    }
    html += "</section><section id=\"aria\"><h2>role-overridden + contenteditable</h2>"
    for i in 1...Counts.roleButtonDivs {
      html += "<div role=\"button\" tabindex=\"0\">role-btn-\(i)</div> "
    }
    for i in 1...Counts.roleLinkDivs {
      html += "<div role=\"link\" tabindex=\"0\">role-link-\(i)</div> "
    }
    for i in 1...Counts.contentEditables {
      html += "<div contenteditable=\"true\">ce-\(i)</div> "
    }
    html += "</section><section id=\"headings\"><h2>headings (MUST NOT HINT)</h2>"
    for i in 1...Counts.headings {
      let level = (i % 3) + 1
      html += "<h\(level)>heading-\(i)</h\(level)> "
    }
    html += "</section><section id=\"paragraphs\"><h2>paragraphs + plain divs (MUST NOT HINT)</h2>"
    for i in 1...Counts.paragraphs {
      html += "<p>paragraph-\(i)</p>"
    }
    for i in 1...Counts.plainDivs {
      html += "<div>plain-div-\(i)</div>"
    }
    html += "</section><section id=\"plain-imgs\"><h2>decorative images (MUST NOT HINT)</h2>"
    for i in 1...Counts.plainImages {
      html += "<img alt=\"plain-\(i)\"> "
    }
    html += "</section><section id=\"disabled\"><h2>disabled controls (MUST NOT HINT)</h2>"
    for i in 1...Counts.disabledButtons {
      html += "<button disabled>disabled-btn-\(i)</button> "
    }
    for i in 1...Counts.disabledInputs {
      html += "<input type=\"text\" disabled value=\"disabled-input-\(i)\"> "
    }
    html += """
      </section><section id="aria-hidden" aria-hidden="true"><h2>aria-hidden subtree (MUST NOT HINT)</h2>
      """
    for i in 1...Counts.ariaHiddenButtons {
      html += "<button>aria-hidden-btn-\(i)</button> "
    }
    for i in 1...Counts.ariaHiddenInputs {
      html += "<input type=\"text\" value=\"aria-hidden-input-\(i)\"> "
    }
    html += """
      </section><section id="display-none" style="display:none"><h2>display:none subtree (MUST NOT HINT)</h2>
      """
    for i in 1...Counts.displayNoneButtons {
      html += "<button>display-none-btn-\(i)</button> "
    }
    html += """
      </section><section id="offscreen-flood" class="offscreen-flood">
      <h2>offscreen clickable flood</h2><div class="offscreen-flood-grid">
      """
    for i in 1...Counts.offscreenButtons {
      html += "<button>far-btn-\(i)</button>"
    }
    html += "</div></section></body></html>"
    return html
  }()
}
