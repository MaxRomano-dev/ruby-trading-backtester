#!/usr/bin/env ruby

# Stable project root shared by files under lib/trading_bot.
BOT_ROOT = File.expand_path(__dir__) unless defined?(BOT_ROOT)

require_relative "lib/trading_bot/bootstrap"
require_relative "lib/trading_bot/helpers"
require_relative "lib/trading_bot/backtester"

# Preserve the original behavior: command-line execution runs the report
# pipeline, while requiring this file only loads the reusable engine methods.
require_relative "lib/trading_bot/runner" if __FILE__ == $PROGRAM_NAME

verify_tomorrow_orders_vs_trades($all_trades, TOMORROW_ORDERS_CSV)

require_relative "lib/trading_bot/metrics_finalizer"
