require "test_helper"

class GroupsTest < ActiveSupport::TestCase
  Groups = PocketKit::Errors::Groups

  test "the fingerprint ignores numbers and addresses in the message but not the class or top frame" do
    base = Groups.fingerprint("NoMethodError", "undefined method for #<Note id: 4 at 0x7f3a>", "a.rb:1")

    assert_equal base, Groups.fingerprint("NoMethodError", "undefined method for #<Note id: 52 at 0x9b00>", "a.rb:1")
    assert_not_equal base, Groups.fingerprint("NameError", "undefined method for #<Note id: 4 at 0x7f3a>", "a.rb:1")
    assert_not_equal base, Groups.fingerprint("NoMethodError", "undefined method for #<Note id: 4 at 0x7f3a>", "b.rb:1")
    assert_match(/\A\h{16}\z/, base)
  end

  test "the fingerprint matches the Python helper's" do
    assert_equal "f15f708a2de14776", Groups.fingerprint("ValueError", "bad id 42", "app.py:10")
  end

  test "the first occurrence is sent, repeats in the window are held, the next one after it carries the count" do
    groups = Groups.new(window: 60)
    start = Time.utc(2026, 1, 1)

    assert_equal({ fingerprint: "f", count: 1, first_seen: start, last_seen: start }, groups.record("f", now: start))
    assert_nil groups.record("f", now: start + 10)
    assert_nil groups.record("f", now: start + 20)
    assert_equal({ fingerprint: "f", count: 3, first_seen: start + 10, last_seen: start + 61 },
                 groups.record("f", now: start + 61))
    assert_equal 1, groups.record("f", now: start + 200)[:count]
  end

  test "only MAX_GROUPS fingerprints are remembered" do
    groups = Groups.new(window: 60)
    now = Time.utc(2026, 1, 1)
    (Groups::MAX_GROUPS + 1).times { |i| groups.record("f#{i}", now: now) }

    assert groups.record("f0", now: now), "the oldest group was forgotten, so it is sent again"
    assert_nil groups.record("f#{Groups::MAX_GROUPS}", now: now)
  end
end
