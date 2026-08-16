require "minitest/autorun"
require "csv"
require "date"
require "fileutils"
require "tmpdir"

BOT_ROOT = File.expand_path("..", __dir__) unless defined?(BOT_ROOT)
RESULTS_DIR = File.join(Dir.tmpdir, "ruby_trading_backtester_tests") unless defined?(RESULTS_DIR)

require_relative "../lib/trading_bot/helpers"

class HelpersTest < Minitest::Test
  def test_next_trading_day_moves_monday_to_tuesday
    assert_equal "2026-08-18", next_trading_day_str("2026-08-17")
  end

  def test_next_trading_day_skips_weekend
    assert_equal "2026-08-17", next_trading_day_str("2026-08-14")
  end

  def test_rsi_requires_enough_prices
    assert_empty calculate_rsi([100.0, 101.0], 2)
  end

  def test_rsi_is_100_for_only_gains
    result = calculate_rsi([100.0, 101.0, 102.0], 2)

    assert_equal 2, result.last.first
    assert_in_delta 100.0, result.last.last, 0.001
  end

  def test_rsi_is_zero_for_only_losses
    result = calculate_rsi([102.0, 101.0, 100.0], 2)

    assert_in_delta 0.0, result.last.last, 0.001
  end

  def test_rsi_is_neutral_for_flat_prices
    result = calculate_rsi([100.0, 100.0, 100.0], 2)

    assert_in_delta 50.0, result.last.last, 0.001
  end

  def test_grade_label_marks_strong_results_as_excellent
    assert_equal ["Excellent", "✅"], grade_label(
      pf: 1.8,
      win: 65,
      cagr: 10,
      maxdd: 15,
      trades: 45
    )
  end

  def test_grade_label_rejects_too_few_trades
    assert_equal ["Low", "❌"], grade_label(
      pf: 3.0,
      win: 90,
      cagr: 30,
      maxdd: 5,
      trades: 19
    )
  end

  def test_compute_stats_for_empty_trade_list
    expected = { trades: 0, win_rate: 0, pf: 0, cagr: 0 }

    assert_equal expected, compute_stats([], "2025-01-01", "2026-01-01")
  end

  def test_compute_stats_calculates_trade_count_win_rate_and_profit_factor
    trades = [
      { pct_return: 10.0 },
      { pct_return: -5.0 },
      { pct_return: 5.0 }
    ]

    stats = compute_stats(trades, "2025-01-01", "2026-01-01")

    assert_equal 3, stats[:trades]
    assert_in_delta 66.67, stats[:win_rate], 0.01
    assert_in_delta 3.0, stats[:pf], 0.001
    assert_operator stats[:cagr], :>, 0
  end

  def test_detect_sep_recognizes_comma_semicolon_and_tab
    Dir.mktmpdir do |dir|
      comma = File.join(dir, "comma.csv")
      semicolon = File.join(dir, "semicolon.csv")
      tab = File.join(dir, "tab.tsv")
      File.write(comma, "date,open,close\n")
      File.write(semicolon, "date;open;close\n")
      File.write(tab, "date\topen\tclose\n")

      assert_equal ",", detect_sep(comma)
      assert_equal ";", detect_sep(semicolon)
      assert_equal "\t", detect_sep(tab)
    end
  end

  def test_calculate_atr_aligns_results_with_input_rows
    rows = CSV.parse(<<~CSV, headers: true)
      high,low,close
      10,8,9
      12,9,11
      13,10,12
      15,11,14
    CSV

    result = calculate_atr(rows, 2)

    assert_equal rows.size, result.size
    assert_nil result[0]
    assert_nil result[1]
    assert_in_delta 3.0, result[2], 0.001
    assert_in_delta 3.5, result[3], 0.001
  end

  def test_append_tomorrow_order_prevents_exact_duplicates
    Dir.mktmpdir do |dir|
      path = File.join(dir, "tomorrow_orders.csv")
      reset_tomorrow_orders!(path)

      2.times do
        append_tomorrow_order!(
          path,
          signal: "BUY",
          symbol: "NVDA",
          signal_date: "2026-08-14",
          close_price: 180.0
        )
      end

      rows = CSV.read(path, headers: true)
      assert_equal 1, rows.size
      assert_equal "2026-08-17", rows.first["date"]
      assert_equal "PENDING", rows.first["executed_entry"]
    end
  end
end
