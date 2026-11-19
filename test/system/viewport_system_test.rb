require "test_helper"
require "capybara/rails"

class ViewportSystemTest < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 390, 844 ]

  def wait_for_script
    Timeout.timeout(5) { sleep 0.05 until evaluate_script("typeof window.PocketKitViewport === 'object'") }
  end

  def call(js)
    wait_for_script
    evaluate_script("(() => { const V = window.PocketKitViewport; return #{js} })()")
  end

  test "visibleBox follows the visual viewport" do
    visit root_path
    assert_equal({ "top" => 0, "height" => 400 }, call("V.visibleBox({ height: 400, offsetTop: 0 })"))
    assert_equal({ "top" => 120, "height" => 400.5 }, call("V.visibleBox({ height: 400.5, offsetTop: 120 })"))
    assert_equal({ "top" => 0, "height" => 400 }, call("V.visibleBox({ height: 400, offsetTop: -3 })"))
    assert_nil call("V.visibleBox(undefined)")
    assert_nil call("V.visibleBox({ height: 0, offsetTop: 0 })")
    assert_nil call("V.visibleBox({ height: NaN, offsetTop: 0 })")
  end

  test "only the first tap into an empty text field is taken over" do
    visit root_path
    assert call("V.shouldInterceptTap({ textField: true, focused: false, hasValue: false })")
    assert_not call("V.shouldInterceptTap({ textField: true, focused: true, hasValue: false })")
    assert_not call("V.shouldInterceptTap({ textField: true, focused: false, hasValue: true })")
    assert_not call("V.shouldInterceptTap({ textField: false, focused: false, hasValue: false })")
  end

  test "drags that would pan the page are blocked, others are left alone" do
    visit root_path
    base = "touches: 1, inScroller: false, selectionCollapsed: true, scrollableField: false"
    assert call("V.shouldBlockTouchMove({ #{base} })")
    assert_not call("V.shouldBlockTouchMove({ #{base}, touches: 2 })")
    assert_not call("V.shouldBlockTouchMove({ #{base}, inScroller: true })")
    assert_not call("V.shouldBlockTouchMove({ #{base}, selectionCollapsed: false })")
    assert_not call("V.shouldBlockTouchMove({ #{base}, scrollableField: true })")
  end

  test "an opted-in page is pinned to the visible area and scrolls inside its scroller" do
    visit pinned_path
    wait_for_script
    height = evaluate_script("window.visualViewport.height")
    assert_equal "#{height.to_i}px", evaluate_script("document.documentElement.style.getPropertyValue('--pk-visible-height')").sub(/\.\d+/, "")
    assert_equal "fixed", evaluate_script("getComputedStyle(document.body).position")

    execute_script("document.querySelector('[data-pk-scroll]').scrollTop = 10000")
    assert_equal 0, evaluate_script("document.querySelector('header').getBoundingClientRect().top")
    composer_bottom = evaluate_script("document.getElementById('composer').getBoundingClientRect().bottom")
    assert_in_delta height, composer_bottom, 1
  end

  test "horizontal drags in overflowing text fields are left alone" do
    visit pinned_path
    wait_for_script
    result = evaluate_script(<<~JS)
      (() => {
        const field = document.createElement("textarea")
        field.style.cssText = "width: 40px; white-space: pre; overflow: auto"
        field.value = "A value much wider than the field"
        document.getElementById("composer").appendChild(field)
        const event = new Event("touchmove", { bubbles: true, cancelable: true })
        field.dispatchEvent(event)
        return { overflow: field.scrollWidth > field.clientWidth, prevented: event.defaultPrevented }
      })()
    JS
    assert result["overflow"]
    assert_not result["prevented"]
  end

  test "Turbo activates the piece only on opted-in pages" do
    visit pinned_path
    wait_for_script
    assert_not_equal "", evaluate_script("document.documentElement.style.getPropertyValue('--pk-visible-height')")

    execute_script("Turbo.visit('/')")
    assert_text "Home"
    assert_equal "", evaluate_script("document.documentElement.style.getPropertyValue('--pk-visible-height')")
    assert_equal "static", evaluate_script("getComputedStyle(document.body).position")

    execute_script("Turbo.visit('/pinned')")
    assert_selector "#composer"
    assert_not_equal "", evaluate_script("document.documentElement.style.getPropertyValue('--pk-visible-height')")
  end

  test "a page without the attribute is left alone" do
    visit root_path
    wait_for_script
    assert_equal "", evaluate_script("document.documentElement.style.getPropertyValue('--pk-visible-height')")
    assert_equal "static", evaluate_script("getComputedStyle(document.body).position")
  end
end
