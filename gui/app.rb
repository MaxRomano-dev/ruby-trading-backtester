# frozen_string_literal: true

require "sinatra"
require "open3"
require "yaml"
require "json"
require "securerandom"
require "fileutils"
require "date"
require "csv"
require "time"

set :bind, "127.0.0.1"
set :port, 4567
set :server, :puma
set :public_folder, File.join(__dir__, "public")
set :views, File.join(__dir__, "views")

ROOT = File.expand_path("..", __dir__)
CONFIG = YAML.safe_load_file(File.join(__dir__, "config.yml"), aliases: false)
RUNS_DIR = File.join(__dir__, "runs")
DATA_RUNS_DIR = File.join(__dir__, "data_runs")
TRADE_CSV_PATH = File.join(ROOT, "storage", "default", "vanilla", "whatif_nextopen_trades.csv")
FileUtils.mkdir_p(RUNS_DIR)
FileUtils.mkdir_p(DATA_RUNS_DIR)
RUNS = {}
RUNS_MUTEX = Mutex.new
DATA_JOBS = {}
DATA_JOBS_MUTEX = Mutex.new

ALLOWED_MODES = %w[backtest sweep].freeze
DEFAULT_SYMBOLS = %w[NVDA MOD LRCX VRT VST AMD DELL TSM GS TSLA].freeze
DEFAULT_DOWNLOAD_SYMBOLS = %w[QQQ VIXY LRCX NVDA DELL VST AMD VRT MOD CAT TSM TSLA GS AVGO].freeze
DEFAULT_DATA_TRADE_SYMBOLS = %w[NVDA MOD LRCX AVGO DELL AMD VRT CAT TSM TSLA GS VST].freeze

helpers do
  def numeric(value, fallback)
    Float(value.to_s)
    value.to_s
  rescue ArgumentError, TypeError
    fallback.to_s
  end

  def integer(value, fallback)
    Integer(value.to_s)
    value.to_s
  rescue ArgumentError, TypeError
    fallback.to_s
  end

  def clean_date(value, fallback)
    value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? value.to_s : fallback
  end

  def clean_symbols(value)
    value.to_s.split(/[\s,]+/).filter_map do |symbol|
      base = symbol.upcase.gsub(/[^A-Z0-9._-]/, "")
      next if base.empty?
      base.match?(/_GOOGLEFINANCE_/i) ? base : "#{base}_GoogleFinance_AutoUpToDate"
    end.uniq.first(100)
  end

  def base_symbols(value)
    clean_symbols(value).map { |symbol| symbol.split("_").first }
  end

  def configured_script(key)
    path = File.expand_path(CONFIG.fetch(key), ROOT)
    raise ArgumentError, "Configured #{key} is outside the bot folder." unless path == ROOT || path.start_with?(ROOT + File::SEPARATOR)
    raise ArgumentError, "Required script not found: #{File.basename(path)}" unless File.file?(path)
    path
  end

  def data_commands_for(input)
    action = %w[update verify update_run].include?(input["action"]) ? input["action"] : "verify"
    download_symbols = clean_symbols(input["download_symbols"])
    raise ArgumentError, "Choose at least one data symbol." if download_symbols.empty?
    prices_dir = File.expand_path(CONFIG.fetch("tiingo_prices_dir", "data/clean-tiingo/data/prices"), ROOT)
    raise ArgumentError, "Configured Tiingo directory is outside the bot folder." unless prices_dir.start_with?(ROOT + File::SEPARATOR)
    verify = [RbConfig.ruby, configured_script("date_checker_file"), "--dir", prices_dir, "--symbols", download_symbols.join(",")]
    return [["Verify dates", verify]] if action == "verify"

    current_data = input["data_source"] == "current"
    downloader_key = current_data ? "tiingo_current_downloader_file" : "tiingo_downloader_file"
    downloader_label = current_data ? "Download current/live Tiingo data" : "Download standard Tiingo data"
    commands = [
      [downloader_label, [RbConfig.ruby, configured_script(downloader_key), *download_symbols]],
      ["Verify dates", verify],
      ["Move cleaned files", [RbConfig.ruby, configured_script("clean_mover_file")]]
    ]
    commands << ["Run trading bot", command_for(input)] if action == "update_run"
    commands
  end

  def data_file_for(symbol)
    full = clean_symbols(symbol).first
    return nil unless full
    base = full.split("_").first
    roots = [
      File.expand_path(CONFIG.fetch("tiingo_prices_dir", "data/clean-tiingo/data/prices"), ROOT),
      File.join(ROOT, "data", "clean")
    ]
    roots.each do |dir|
      next unless Dir.exist?(dir)
      candidates = Dir.glob(File.join(dir, "*.csv"), File::FNM_CASEFOLD)
      exact = candidates.find { |path| File.basename(path, ".csv").casecmp?(full) }
      return exact if exact
      fallback = candidates.find { |path| File.basename(path).upcase.start_with?(base + "_") }
      return fallback if fallback
    end
    nil
  end

  def data_status_row(symbol)
    base = base_symbols(symbol).first
    path = data_file_for(symbol)
    return { symbol: base, status: "Missing", rows: 0, first_date: nil, last_date: nil } unless path
    rows = 0
    first_date = nil
    last_date = nil
    csv_text = File.read(path, encoding: "bom|utf-8", invalid: :replace, undef: :replace)
    CSV.parse(csv_text, headers: true) do |row|
      value = row["date"] || row["Date"] || row[0]
      raw_date = value.to_s.strip
      date = if raw_date.match?(/\A\d{4}-\d{2}-\d{2}/)
        raw_date[0, 10]
      else
        Date.parse(raw_date).to_s
      end
      first_date ||= date
      last_date = date
      rows += 1
    rescue Date::Error
      next
    end
    status = rows.positive? ? "Available" : "No dated rows"
    { symbol: base, status: status, rows: rows, first_date: first_date, last_date: last_date, file: File.basename(path), detail: File.basename(path) }
  rescue StandardError => e
    { symbol: base, status: "Invalid", rows: 0, first_date: nil, last_date: nil, detail: e.message }
  end

  def append_tomorrow_orders(log_path)
    orders_path = File.join(ROOT, "storage", "default", "vanilla", "tomorrow_orders.csv")
    File.open(log_path, "a") do |log|
      log.puts "\n=== Displaying Tomorrow's Orders ==="
      if File.file?(orders_path)
        log.puts
        lines = File.readlines(orders_path, encoding: "bom|utf-8", invalid: :replace, undef: :replace)
        lines.shift
        displayed = 0
        recovered = 0
        lines.each do |line|
          next if line.strip.empty?
          values = begin
            CSV.parse_line(line, liberal_parsing: true)
          rescue CSV::MalformedCSVError
            recovered += 1
            line.strip.split(",", -1).map { |value| value.delete_prefix('"').delete_suffix('"') }
          end
          next unless values
          log.puts values.map { |value| value.to_s.strip }.join(" | ")
          displayed += 1
        end
        log.puts "⚠️ Recovered #{recovered} malformed row(s)." if recovered.positive?
        log.puts "No order rows found." if displayed.zero?
      else
        log.puts "⚠️ No tomorrow_orders.csv found."
      end
      log.puts "=== Finished! ==="
    end
  rescue StandardError => e
    File.open(log_path, "a") do |log|
      log.puts "⚠️ Could not read tomorrow_orders.csv: #{e.message}"
      log.puts "=== Finished! ==="
    end
  end

  def command_for(input)
    mode = ALLOWED_MODES.include?(input["mode"]) ? input["mode"] : "backtest"
    symbols = clean_symbols(input["symbols"])
    raise ArgumentError, "Choose at least one symbol." if symbols.empty?

    command = [
      RbConfig.ruby,
      File.join(ROOT, CONFIG.fetch("bot_file")),
      "--symbols", symbols.join(","),
      "--from", clean_date(input["from"], "2020-01-01"),
      "--to", clean_date(input["to"], Date.today.to_s)
    ]
    if input["settings_source"] == "manual"
      command.concat([
        "--rsi2-period", integer(input["rsi2_period"], 3),
        "--rsi3-period", integer(input["rsi3_period"], 3),
        "--oversold", numeric(input["oversold"], 22),
        "--overbought", numeric(input["overbought"], 85),
        "--breakout-entry", integer(input["breakout_entry"], 12),
        "--breakout-exit", integer(input["breakout_exit"], 4),
        "--sma-filter", integer(input["sma_filter"], 200),
        "--atr-stop", numeric(input["atr_stop"], 6.0),
        "--atr-profit", numeric(input["atr_profit"], 3.0)
      ])
    end
    command.concat(["--start-equity", numeric(input["start_equity"], 50_000)])
    command << "--one-trade" if input["one_trade"] == true
    command.concat(Array(CONFIG.dig("modes", mode)))
  end

  def display_command(command)
    command.map { |part| part.match?(/[\s,"]/) ? %Q{"#{part.gsub('"', '\\"')}"} : part }.join(" ")
  end

  def equity_points_from(text)
    clean = text.gsub(/\e\[[0-?]*[ -\/]*[@-~]/, "")
    by_year = {}
    lines = clean.each_line.to_a
    marker_index = lines.index { |line| line.include?("Yearly (Next-Open, Fees+Slippage)") }
    selected_lines = marker_index ? lines[(marker_index + 1)..] : lines
    started = false
    selected_lines.each do |line|
      year = line[/\b(20\d{2})\b/, 1]
      if !year
        break if started
        next
      end

      money = line.scan(/\$\s*([\d,]+(?:\.\d+)?)/).flatten
      next if money.length < 2

      by_year[year.to_i] = money[1].delete(",").to_f
      started = true
    end
    by_year.sort.map { |year, equity| { year: year, equity: equity } }
  end

  def log_payload(path)
    text = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
    run_id = File.basename(path, ".log")
    run_trade_path = File.join(RUNS_DIR, "#{run_id}_trades.csv")
    points = equity_points_from(text)
    finished = text.include?("[GUI] Process finished") || text.include?("[GUI ERROR]")
    trade_data = finished ? trade_analysis_from(text, File.file?(run_trade_path) ? run_trade_path : nil) : { curve: [], symbols: [] }
    benchmark = finished ? benchmark_points_from(text) : { points: [], status: "Available after a completed run." }
    next_open_metrics = finished ? next_open_metrics_from(text, trade_data[:symbols]) : {}
    if trade_data[:symbols].length == 1 && next_open_metrics[:cagr]
      trade_data[:symbols].first[:cagr] = next_open_metrics[:cagr]
    end
    signal_data = signal_data_from(text, include_storage: finished)
    {
      output: text,
      finished: finished,
      equity_points: points,
      final_equity: points.last&.dig(:equity),
      trade_equity_points: trade_data[:curve],
      symbol_results: trade_data[:symbols],
      next_open_metrics: next_open_metrics,
      tomorrow_signals: signal_data[:orders],
      recent_signals: signal_data[:recent],
      benchmark_points: benchmark[:points],
      benchmark_status: benchmark[:status]
    }
  end

  def signal_data_from(_log_text, include_storage: false)
    latest_signals = {}
    storage_signals = include_storage ? tomorrow_order_rows : []
    if include_storage
      storage_signals.group_by { |row| row[:symbol] }.each_value do |rows|
        candidate = rows.max_by { |row| row[:date] }
        current = latest_signals[candidate[:symbol]]
        latest_signals[candidate[:symbol]] = candidate if current.nil? || candidate[:date] >= current[:date]
      end
    end
    orders = storage_signals.sort_by { |row| [row[:date].to_s, row[:symbol]] }.reverse.first(5).map do |row|
      pending = row[:signal] == "BUY" ? row[:entry_pending] : row[:exit_pending]
      row.merge(execution: pending ? "PENDING" : "—")
    end
    {
      orders: orders.sort_by { |row| [row[:date].to_s, row[:symbol]] }.reverse,
      recent: latest_signals.values.sort_by { |row| [row[:date].to_s, row[:symbol]] }.reverse.first(8)
    }
  end

  def tomorrow_order_rows
    path = File.join(File.dirname(TRADE_CSV_PATH), "tomorrow_orders.csv")
    return [] unless File.file?(path)
    lines = File.readlines(path, encoding: "bom|utf-8", invalid: :replace, undef: :replace)
    headers = lines.shift.to_s.strip.split(",").map { |header| header.downcase.strip }
    date_index = headers.index("date")
    symbol_index = headers.index("symbol")
    signal_index = headers.index("signal")
    close_index = headers.index("close")
    entry_index = headers.index("executed_entry")
    exit_index = headers.index("executed_exit")
    return [] unless date_index && symbol_index && signal_index && close_index
    lines.filter_map do |line|
      values = line.strip.split(",", -1)
      date = values[date_index].to_s[0, 10]
      signal = values[signal_index].to_s.upcase
      price = Float(values[close_index].to_s.delete(","), exception: false)
      next unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/) && %w[BUY SELL EXIT HOLD].include?(signal) && price
      {
        symbol: values[symbol_index].to_s.split("_").first.upcase,
        signal: signal,
        price: price,
        date: date,
        entry_pending: entry_index && values[entry_index].to_s.delete('"').strip.casecmp?("PENDING"),
        exit_pending: exit_index && values[exit_index].to_s.delete('"').strip.casecmp?("PENDING")
      }
    end
  rescue StandardError
    []
  end

  def next_open_metrics_from(log_text, symbol_results)
    marker = "Next-Open (What-If) vs Current"
    return {} unless log_text.include?(marker)
    section = log_text.split(marker, 2).last.lines.first(20).join
    weighted_rows = symbol_results.select { |row| row[:trades].to_i.positive? && !row[:win_rate].nil? }
    total_weight = weighted_rows.sum { |row| row[:trades].to_i }
    weighted_win_rate = if total_weight.positive?
      weighted_rows.sum { |row| row[:win_rate].to_f * row[:trades].to_i } / total_weight
    end
    {
      trades: section[/^Trades:\s*(\d+)/, 1]&.to_i,
      cagr: section[/^CAGR:\s*([-\d.]+)%/, 1]&.to_f,
      pf: section[/^PF:\s*([-\d.]+)/, 1]&.to_f,
      maxdd: section[/^MaxDD:\s*([-\d.]+)%/, 1]&.to_f,
      winrate: weighted_win_rate&.round(2)
    }.compact
  end

  def run_metadata_path(run_id)
    File.join(RUNS_DIR, "#{run_id}.json")
  end

  def write_run_metadata(run_id, values)
    path = run_metadata_path(run_id)
    current = File.file?(path) ? JSON.parse(File.read(path)) : {}
    normalized_values = values.to_h { |key, value| [key.to_s, value] }
    File.write(path, JSON.pretty_generate(current.merge(normalized_values)))
  rescue JSON::ParserError
    File.write(path, JSON.pretty_generate(normalized_values || values))
  end

  def inferred_run_metadata(path)
    run_id = File.basename(path, ".log")
    text = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
    command = text.lines.first.to_s.sub(/^\$\s*/, "").strip
    symbol_text = command[/--symbols\s+"?([^"\s]+)/, 1].to_s
    {
      id: run_id,
      started_at: File.mtime(path).utc.iso8601,
      symbols: symbol_text.split(",").map { |symbol| symbol.split("_").first },
      mode: command.include?("--sweep") ? "sweep" : "backtest",
      status: text.include?("Run stopped by user") ? "stopped" : (text.include?("[GUI] Process finished") ? "finished" : "unknown"),
      command: command
    }
  end

  def active_run?(run_id)
    RUNS_MUTEX.synchronize { RUNS[run_id] && !RUNS[run_id][:finished] }
  end

  def benchmark_points_from(log_text)
    from = log_text[/--from\s+"?(\d{4}-\d{2}-\d{2})/, 1]
    to = log_text[/--to\s+"?(\d{4}-\d{2}-\d{2})/, 1]
    start_equity = log_text[/--start-equity\s+"?([\d,.]+)/, 1].to_s.delete(",").to_f
    start_equity = 50_000.0 unless start_equity.positive?
    return { points: [], status: "Run dates were not found in the saved command." } unless from && to

    preferred_path = File.join(ROOT, "data", "clean", "QQQ_GOOGLEFINANCE_AUTOUPTODATE.csv")
    path = File.file?(preferred_path) ? preferred_path : nil
    unless path
      glob_pattern = File.join(ROOT, "**", "*.csv").tr("\\", "/")
      candidates = Dir.glob(glob_pattern, File::FNM_CASEFOLD).select do |candidate|
        File.basename(candidate).upcase.include?("QQQ") && !candidate.start_with?(File.join(__dir__, "runs"))
      end
      path = candidates.find { |candidate| File.basename(candidate).casecmp?("QQQ_GOOGLEFINANCE_AUTOUPTODATE.csv") }
    end
    return { points: [], status: "QQQ CSV not found at data/clean/QQQ_GOOGLEFINANCE_AUTOUPTODATE.csv." } unless path && File.file?(path)

    from_date = Date.parse(from)
    to_date = Date.parse(to)
    lines = File.readlines(path, encoding: "bom|utf-8", invalid: :replace, undef: :replace)
    headers = lines.shift.to_s.strip.split(",").map { |header| header.downcase.gsub(/[^a-z0-9]/, "") }
    date_index = %w[date datetime timestamp time].filter_map { |name| headers.index(name) }.first
    close_index = %w[close adjclose adjustedclose closeprice price].filter_map { |name| headers.index(name) }.first
    return { points: [], status: "QQQ CSV was found, but its date or close column was not recognized." } unless date_index && close_index

    skipped_rows = 0
    prices = lines.filter_map do |line|
      values = line.strip.split(",", -1)
      date = values[date_index]
      close = values[close_index]
      unless date && close && values.length > [date_index, close_index].max
        skipped_rows += 1
        next
      end
      begin
        parsed_date = Date.parse(date.to_s)
      rescue Date::Error
        skipped_rows += 1
        next
      end
      next unless parsed_date >= from_date && parsed_date <= to_date
      value = close.to_s.delete(",$").to_f
      unless value.positive?
        skipped_rows += 1
        next
      end
      [parsed_date.to_s, value]
    end.sort_by(&:first)
    return { points: [], status: "QQQ CSV was found, but it had no readable prices inside the run date range." } if prices.empty?

    base = prices.first[1]
    points = prices.map { |date, close| { label: date, equity: (start_equity * close / base).round(2), symbol: "QQQ" } }
    # Keep the chart responsive for very long daily histories while retaining both endpoints.
    if points.length > 500
      step = (points.length / 499.0).ceil
      sampled = points.each_slice(step).map(&:first)
      sampled << points.last unless sampled.last == points.last
      points = sampled
    end
    skipped_note = skipped_rows.positive? ? " Skipped #{skipped_rows} malformed rows." : ""
    { points: points, status: "Loaded #{prices.length} QQQ prices from #{File.basename(path)}.#{skipped_note}" }
  rescue StandardError => e
    # The benchmark is optional and must never prevent the completed run from loading.
    { points: [], status: "QQQ benchmark error: #{e.class}: #{e.message}" }
  end

  def console_symbol_results(log_text)
    results = {}
    log_text.each_line do |line|
      next unless line.include?("[RESULT]")
      match = line.match(/\[RESULT\]\s+([^|\s]+)\s*\|\s*Trades=(\d+)\s*\|\s*PF=([-\d.]+)\s*\|\s*CAGR=([-\d.]+)%/i)
      next unless match
      symbol = match[1].split("_").first
      results[symbol] = { symbol: symbol, trades: match[2].to_i, pf: match[3].to_f, win_rate: nil, compounded_return: nil, cagr: match[4].to_f }
    end
    results
  end

  def trade_analysis_from(log_text, csv_path = nil)
    console_results = console_symbol_results(log_text)
    return { curve: [], symbols: console_results.values.sort_by { |row| row[:symbol] } } unless csv_path && File.file?(csv_path)

    start_equity = log_text[/--start-equity\s+"?([\d,.]+)/, 1].to_s.delete(",").to_f
    start_equity = 50_000.0 unless start_equity.positive?
    lines = File.readlines(csv_path, encoding: "bom|utf-8", invalid: :replace, undef: :replace)
    headers = lines.shift.to_s.strip.split(",").map { |header| header.downcase.strip }
    symbol_index = headers.index("symbol")
    entry_date_index = headers.index("entry_date")
    exit_date_index = headers.index("exit_date")
    return_index = headers.index("pct_return")
    return { curve: [], symbols: console_results.values.sort_by { |row| row[:symbol] } } unless symbol_index && exit_date_index && return_index

    rows = lines.filter_map do |line|
      values = line.strip.split(",", -1)
      symbol = values[symbol_index]
      exit_date = values[exit_date_index]
      return_value = values[return_index]
      next if symbol.to_s.empty? || exit_date.to_s.empty? || return_value.to_s.empty?
      parsed_return = Float(return_value, exception: false)
      next unless parsed_return
      {
        symbol: symbol.split("_").first,
        entry_date: entry_date_index ? values[entry_date_index] : exit_date,
        exit_date: exit_date,
        return: parsed_return
      }
    end.sort_by { |row| row[:exit_date] }
    return { curve: [], symbols: console_results.values.sort_by { |row| row[:symbol] } } if rows.empty?

    equity = start_equity
    curve = [{ label: rows.first[:entry_date], equity: equity.round(2), symbol: "Start" }]
    grouped = Hash.new { |hash, symbol| hash[symbol] = [] }
    rows.each do |row|
      equity *= 1.0 + row[:return] / 100.0
      curve << { label: row[:exit_date], equity: equity.round(2), symbol: row[:symbol] }
      grouped[row[:symbol]] << row
    end
    csv_symbols = grouped.map do |symbol, trade_rows|
      returns = trade_rows.map { |row| row[:return] }
      wins = returns.select(&:positive?)
      losses = returns.select(&:negative?)
      gross_profit = wins.sum
      gross_loss = losses.sum.abs
      growth_factor = returns.reduce(1.0) { |factor, value| factor * (1.0 + value / 100.0) }
      compounded = (growth_factor - 1.0) * 100.0
      symbol_start = Date.parse(trade_rows.first[:entry_date].to_s)
      symbol_end = Date.parse(trade_rows.last[:exit_date].to_s)
      symbol_years = (symbol_end - symbol_start).to_f / 365.25
      cagr = if symbol_years.positive? && growth_factor.positive?
        (growth_factor**(1.0 / symbol_years) - 1.0) * 100.0
      end
      {
        symbol: symbol,
        trades: returns.length,
        pf: gross_loss.positive? ? (gross_profit / gross_loss).round(2) : nil,
        cagr: cagr&.round(2),
        win_rate: (wins.length.to_f / returns.length * 100.0).round(2),
        compounded_return: compounded.round(2)
      }
    end.to_h { |row| [row[:symbol], row] }
    merged_symbols = console_results.merge(csv_symbols) { |_symbol, console_row, csv_row| console_row.merge(csv_row) }.values.sort_by { |row| row[:symbol] }
    { curve: curve, symbols: merged_symbols }
  rescue StandardError
    { curve: [], symbols: console_symbol_results(log_text).values.sort_by { |row| row[:symbol] } }
  end
end

get "/" do
  erb :index, locals: { symbols: DEFAULT_SYMBOLS, download_symbols: DEFAULT_DOWNLOAD_SYMBOLS, data_trade_symbols: DEFAULT_DATA_TRADE_SYMBOLS }
end

post "/api/data/status" do
  content_type :json
  input = JSON.parse(request.body.read)
  symbols = base_symbols(input["download_symbols"])
  halt 422, { error: "Choose at least one data symbol." }.to_json if symbols.empty?
  { rows: symbols.map { |symbol| data_status_row(symbol) }, checked_at: Time.now.utc.iso8601 }.to_json
rescue JSON::ParserError
  status 422
  { error: "Invalid request." }.to_json
end

post "/api/data/run" do
  content_type :json
  input = JSON.parse(request.body.read)
  commands = data_commands_for(input)
  job_id = SecureRandom.hex(8)
  log_path = File.join(DATA_RUNS_DIR, "#{job_id}.log")
  source_label = input["data_source"] == "current" ? "current/live" : "standard"
  File.write(log_path, "[DATA] Starting #{input['action']} workflow using #{source_label} Tiingo data.\n")
  DATA_JOBS_MUTEX.synchronize { DATA_JOBS[job_id] = { pid: nil, finished: false, step: "Starting" } }
  Thread.new do
    begin
      commands.each_with_index do |(label, command), index|
        File.open(log_path, "a") { |log| log.puts "\n[STEP #{index + 1}/#{commands.length}] #{label}..." }
        exit_code = nil
        File.open(log_path, "a") do |log|
          Open3.popen2e(*command, chdir: ROOT) do |_stdin, output, wait|
            DATA_JOBS_MUTEX.synchronize do
              DATA_JOBS[job_id][:pid] = wait.pid
              DATA_JOBS[job_id][:step] = label
            end
            output.each { |line| log.write(line); log.flush }
            exit_code = wait.value.exitstatus
          end
        end
        stopped = DATA_JOBS_MUTEX.synchronize { DATA_JOBS[job_id] && DATA_JOBS[job_id][:stop_requested] }
        raise "Workflow stopped by user." if stopped
        raise "#{label} failed with exit code #{exit_code}." unless exit_code.zero?
        File.open(log_path, "a") { |log| log.puts "[STEP COMPLETE] #{label}" }
      end
      File.open(log_path, "a") { |log| log.puts "\n[DATA] Workflow finished successfully." }
      append_tomorrow_orders(log_path) if input["action"] == "update_run"
    rescue StandardError => e
      File.open(log_path, "a") { |log| log.puts "\n[DATA ERROR] #{e.message}" }
    ensure
      DATA_JOBS_MUTEX.synchronize do
        DATA_JOBS[job_id] ||= {}
        DATA_JOBS[job_id][:finished] = true
      end
    end
  end
  { job_id: job_id, steps: commands.map(&:first) }.to_json
rescue StandardError => e
  status 422
  { error: e.message }.to_json
end

get "/api/data/run/:id" do
  content_type :json
  halt 404, { error: "Unknown data job." }.to_json unless params[:id].match?(/\A[0-9a-f]{16}\z/)
  path = File.join(DATA_RUNS_DIR, "#{params[:id]}.log")
  halt 404, { error: "Unknown data job." }.to_json unless File.file?(path)
  job = DATA_JOBS_MUTEX.synchronize { DATA_JOBS[params[:id]]&.dup }
  output = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
  { output: output, finished: job ? job[:finished] : true, step: job&.dig(:step), success: output.include?("Workflow finished successfully") }.to_json
end

post "/api/data/run/:id/stop" do
  content_type :json
  halt 404, { error: "Unknown data job." }.to_json unless params[:id].match?(/\A[0-9a-f]{16}\z/)
  job = DATA_JOBS_MUTEX.synchronize { DATA_JOBS[params[:id]]&.dup }
  halt 409, { error: "This data job is no longer active." }.to_json unless job && !job[:finished]
  halt 409, { error: "The data workflow is still preparing its first process." }.to_json unless job[:pid]
  DATA_JOBS_MUTEX.synchronize { DATA_JOBS[params[:id]][:stop_requested] = true }
  Process.kill("KILL", job[:pid])
  { stopped: true }.to_json
rescue Errno::ESRCH
  status 409
  { error: "The process had already finished." }.to_json
end

post "/api/preview" do
  content_type :json
  input = JSON.parse(request.body.read)
  { command: display_command(command_for(input)) }.to_json
rescue StandardError => e
  status 422
  { error: e.message }.to_json
end

post "/api/run" do
  content_type :json
  input = JSON.parse(request.body.read)
  command = command_for(input)
  bot_path = command[1]
  unless File.file?(bot_path)
    status 422
    return({ error: "Bot file not found. Put the GUI folder beside #{CONFIG.fetch('bot_file')}." }.to_json)
  end

  run_id = SecureRandom.hex(8)
  log_path = File.join(RUNS_DIR, "#{run_id}.log")
  File.write(log_path, "$ #{display_command(command)}\n\n")
  write_run_metadata(run_id, {
    id: run_id,
    started_at: Time.now.utc.iso8601,
    symbols: clean_symbols(input["symbols"]).map { |symbol| symbol.split("_").first },
    mode: ALLOWED_MODES.include?(input["mode"]) ? input["mode"] : "backtest",
    status: "running",
    command: display_command(command)
  })
  trade_csv_before = File.file?(TRADE_CSV_PATH) ? [File.mtime(TRADE_CSV_PATH).to_f, File.size(TRADE_CSV_PATH)] : nil
  capture_mode = input["mode"] == "sweep" && %w[overwrite append].include?(input["sweep_capture"]) ? input["sweep_capture"] : nil
  capture_path = File.join(ROOT, "sweep_output_tomorrow_buy_order.txt")

  Thread.new do
    capture = nil
    begin
      capture = capture_mode ? File.open(capture_path, capture_mode == "append" ? "a" : "w") : nil
      File.open(log_path, "a") do |log|
        Open3.popen2e(*command, chdir: ROOT) do |_stdin, output, wait|
          RUNS_MUTEX.synchronize { RUNS[run_id] = { pid: wait.pid, finished: false } }
          output.each do |line|
            log.write(line)
            log.flush
            capture&.write(line)
            capture&.flush
          end
          exit_status = wait.value.exitstatus
          trade_csv_after = File.file?(TRADE_CSV_PATH) ? [File.mtime(TRADE_CSV_PATH).to_f, File.size(TRADE_CSV_PATH)] : nil
          if trade_csv_after && trade_csv_after != trade_csv_before
            begin
              FileUtils.cp(TRADE_CSV_PATH, File.join(RUNS_DIR, "#{run_id}_trades.csv"))
            rescue StandardError => snapshot_error
              log.puts "[GUI WARNING] Could not snapshot trades CSV: #{snapshot_error.message}"
            end
          end
          log.puts "\n[GUI] Process finished with exit code #{exit_status}."
          stopped = RUNS_MUTEX.synchronize { RUNS[run_id] && RUNS[run_id][:stop_requested] }
          final_status = stopped ? "stopped" : (exit_status.zero? ? "finished" : "failed")
          write_run_metadata(run_id, { status: final_status, finished_at: Time.now.utc.iso8601, exit_code: exit_status })
          RUNS_MUTEX.synchronize { RUNS[run_id][:finished] = true if RUNS[run_id] }
        end
      end
    rescue StandardError => e
      File.open(log_path, "a") { |log| log.puts "\n[GUI ERROR] #{e.class}: #{e.message}" }
      write_run_metadata(run_id, { status: "error", finished_at: Time.now.utc.iso8601, error: "#{e.class}: #{e.message}" })
      RUNS_MUTEX.synchronize { RUNS[run_id][:finished] = true if RUNS[run_id] }
    ensure
      capture&.close
    end
  end

  { run_id: run_id, command: display_command(command), sweep_capture_path: capture_mode ? capture_path : nil }.to_json
rescue StandardError => e
  status 422
  { error: e.message }.to_json
end

post "/api/run/:id/stop" do
  content_type :json
  halt 404, { error: "Unknown run." }.to_json unless params[:id].match?(/\A[0-9a-f]{16}\z/)
  run = RUNS_MUTEX.synchronize { RUNS[params[:id]]&.dup }
  halt 409, { error: "This run is no longer active." }.to_json unless run && !run[:finished]

  RUNS_MUTEX.synchronize { RUNS[params[:id]][:stop_requested] = true if RUNS[params[:id]] }
  Process.kill("KILL", run[:pid])
  path = File.join(RUNS_DIR, "#{params[:id]}.log")
  File.open(path, "a") { |log| log.puts "\n[GUI] Run stopped by user." }
  write_run_metadata(params[:id], { status: "stopped", finished_at: Time.now.utc.iso8601 })
  RUNS_MUTEX.synchronize { RUNS[params[:id]][:finished] = true if RUNS[params[:id]] }
  { stopped: true }.to_json
rescue Errno::ESRCH
  status 409
  { error: "The process had already finished." }.to_json
end

get "/api/run/:id" do
  content_type :json
  halt 404, { error: "Unknown run." }.to_json unless params[:id].match?(/\A[0-9a-f]{16}\z/)
  path = File.join(RUNS_DIR, "#{params[:id]}.log")
  halt 404, { error: "Unknown run." }.to_json unless File.file?(path)
  log_payload(path).to_json
end

get "/api/latest" do
  content_type :json
  path = Dir[File.join(RUNS_DIR, "*.log")].max_by { |candidate| File.mtime(candidate) }
  halt 404, { error: "No previous runs." }.to_json unless path
  log_payload(path).to_json
end

get "/api/runs" do
  content_type :json
  runs = Dir[File.join(RUNS_DIR, "*.log")].sort_by { |path| File.mtime(path) }.reverse.first(100).map do |path|
    run_id = File.basename(path, ".log")
    metadata_path = run_metadata_path(run_id)
    if File.file?(metadata_path)
      metadata = JSON.parse(File.read(metadata_path))
      active = active_run?(run_id)
      metadata["status"] = "interrupted" if metadata["status"] == "running" && !active
      metadata
    else
      inferred_run_metadata(path)
    end
  rescue JSON::ParserError
    nil
  end.compact
  { runs: runs }.to_json
end

post "/api/run/:id/name" do
  content_type :json
  run_id = params[:id]
  halt 404, { error: "Unknown run." }.to_json unless run_id.match?(/\A[0-9a-f]{16}\z/)
  log_path = File.join(RUNS_DIR, "#{run_id}.log")
  halt 404, { error: "Unknown run." }.to_json unless File.file?(log_path)
  input = JSON.parse(request.body.read)
  name = input["name"].to_s.strip[0, 80]
  metadata_path = run_metadata_path(run_id)
  File.write(metadata_path, JSON.pretty_generate(inferred_run_metadata(log_path))) unless File.file?(metadata_path)
  write_run_metadata(run_id, { name: name })
  { updated: true, name: name }.to_json
rescue JSON::ParserError
  status 422
  { error: "Invalid request." }.to_json
end

delete "/api/run/:id" do
  content_type :json
  run_id = params[:id]
  halt 404, { error: "Unknown run." }.to_json unless run_id.match?(/\A[0-9a-f]{16}\z/)
  halt 409, { error: "Stop the active run before deleting it." }.to_json if active_run?(run_id)
  targets = [
    File.join(RUNS_DIR, "#{run_id}.log"),
    File.join(RUNS_DIR, "#{run_id}.json"),
    File.join(RUNS_DIR, "#{run_id}_trades.csv")
  ]
  halt 404, { error: "Unknown run." }.to_json unless targets.any? { |path| File.file?(path) }
  targets.each { |path| FileUtils.rm_f(path) }
  RUNS_MUTEX.synchronize { RUNS.delete(run_id) }
  { deleted: true }.to_json
end

delete "/api/runs" do
  content_type :json
  active_ids = RUNS_MUTEX.synchronize { RUNS.filter_map { |id, run| id unless run[:finished] } }
  deleted = 0
  Dir[File.join(RUNS_DIR, "*.log")].each do |log_path|
    run_id = File.basename(log_path, ".log")
    next unless run_id.match?(/\A[0-9a-f]{16}\z/) && !active_ids.include?(run_id)
    [log_path, File.join(RUNS_DIR, "#{run_id}.json"), File.join(RUNS_DIR, "#{run_id}_trades.csv")].each { |path| FileUtils.rm_f(path) }
    RUNS_MUTEX.synchronize { RUNS.delete(run_id) }
    deleted += 1
  end
  { deleted: deleted, active_preserved: active_ids.length }.to_json
end
