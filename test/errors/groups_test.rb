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

    first = groups.record("f", now: start)
    assert_equal({ fingerprint: "f", count: 1, first_seen: start, last_seen: start }, first)
    groups.commit(first, now: start)
    assert_nil groups.record("f", now: start + 10)
    assert_nil groups.record("f", now: start + 20)
    later = groups.record("f", now: start + 61)
    assert_equal({ fingerprint: "f", count: 3, first_seen: start + 10, last_seen: start + 61 }, later)
    groups.commit(later, now: start + 61)
    assert_equal 1, groups.record("f", now: start + 200)[:count]
  end

  test "a failed delivery restores its occurrence and repeats" do
    groups = Groups.new(window: 60)
    start = Time.utc(2026, 1, 1)
    attempt = groups.record("f", now: start)
    assert_nil groups.record("f", now: start + 10)

    groups.rollback(attempt)

    assert_equal({ fingerprint: "f", count: 3, first_seen: start, last_seen: start + 11 },
                 groups.record("f", now: start + 11))
  end

  test "only MAX_GROUPS completed fingerprints are remembered" do
    groups = Groups.new(window: 60)
    now = Time.utc(2026, 1, 1)
    (Groups::MAX_GROUPS + 1).times do |i|
      attempt = groups.record("f#{i}", now: now)
      groups.commit(attempt, now: now)
    end

    assert groups.record("f0", now: now), "the oldest completed group was forgotten"
    assert_nil groups.record("f#{Groups::MAX_GROUPS}", now: now)
  end

  test "failed groups are bounded and the oldest can be retried as new" do
    groups = Groups.new(window: 60)
    now = Time.utc(2026, 1, 1)
    (Groups::MAX_GROUPS + 1).times do |i|
      attempt = groups.record("f#{i}", now: now)
      groups.rollback(attempt)
    end

    assert_equal 1, groups.record("f0", now: now + 1)[:count]
    assert_equal 2, groups.record("f#{Groups::MAX_GROUPS}", now: now + 1)[:count]
  end

  test "an active group is not evicted to enforce the inactive group limit" do
    groups = Groups.new(window: 60)
    now = Time.utc(2026, 1, 1)
    active = groups.record("active", now: now)
    Groups::MAX_GROUPS.times do |i|
      attempt = groups.record("f#{i}", now: now)
      groups.commit(attempt, now: now)
    end

    assert_nil groups.record("active", now: now + 1)
    groups.rollback(active)
    assert_equal 3, groups.record("active", now: now + 2)[:count]
  end
end
