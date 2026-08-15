# =======================================================
#  UNIVERSAL METRIC NORMALIZER (prevents Hash→Integer crash)
# =======================================================
def normalize_global_metrics!
  %i[$profit_factor $win_rate $real_cagr $max_dd].each do |var|
    val = eval(var.to_s) rescue 0
    flat = case val
           when Hash
             val.values.first.to_f rescue 0.0
           when Array
             val.first.to_f rescue 0.0
           else
             val.to_f rescue 0.0
           end
    eval("#{var} = #{flat}")
  end
end

def safe_flat_f(v)
  _flat(v).to_f
rescue
  0.0
end

def safe_flat_s(v)
  _flat(v).to_s
rescue
  ""
end

def log_metrics_file_size(path, label: "METRICS")
  begin
    if path.to_s.strip.empty?
      warn "[#{label}] path is blank"
      return
    end
    unless File.exist?(path)
      warn "[#{label}] #{path} (missing)"
      return
    end

    st = File.stat(path)
    # Optional inode/dev can help confirm you're looking at the same file on networked FS
    puts "[#{label}] size=#{st.size} bytes | mtime=#{st.mtime.utc.iso8601} | inode=#{st.ino} | dev=#{st.dev}"
  rescue => e
    warn "[#{label}_SIZE_ERR] #{e.class}: #{e.message}"
  end
end

# --- safe scalar coercion helpers (place once, above the finalizer) ---
def _flat(v)
  case v
  when Hash  then v.values.first
  when Array then v.first
  else v
  end
end

def _flat_f(v); _flat(v).to_f; end
def _flat_s(v); _flat(v).to_s; end

def write_metrics_finalizer!
  path = ENV["METRICS_CSV"].to_s.strip
  return if path.empty?

  FileUtils.mkdir_p(File.dirname(path)) rescue nil

  # Skip if row 2 already looks like a real result (not a placeholder)
  if File.exist?(path)
    lines = File.readlines(path) rescue []
    row2  = lines[1].to_s.strip
    if !row2.empty? && !(%w[BOOT DONE AT_EXIT SKIP -- #NAME?].any? { |p| row2.start_with?("#{p},") })
      puts "[FINALIZER] Skip: metrics already present (#{row2})"
      return
    end
  end

  trades    = ($all_trades.respond_to?(:size) ? $all_trades.size : 0).to_i
  win_val   = safe_flat_f($win_rate)
  pf_val    = safe_flat_f($profit_factor)
  pf_val    = 1.0 if pf_val.zero?
  cagr_val  = safe_flat_f($real_cagr)
  maxdd_val = safe_flat_f($max_dd)
  sym       = safe_flat_s(ENV["METRICS_SYMBOL"])
  sym       = "TOTAL" if sym.empty? || sym.start_with?("--") || sym =~ /\A#NAME\?/i

  header = %w[symbol trades win_rate pf cagr max_drawdown]

  # Atomic write then rename to avoid partial files
  tmp = "#{path}.tmp-#{$$}"
  CSV.open(tmp, "w") do |csv|
    csv << header
    csv << [sym, trades, win_val, pf_val, cagr_val, maxdd_val]
  end
  begin
    File.open(tmp, File::RDWR, &:fsync)
  rescue => e
    warn "[FINALIZER_FSYNC_TMP_ERR] #{e.class}: #{e.message}"
  end
  File.rename(tmp, path)

  begin
    File.open(path, File::RDWR, &:fsync)
  rescue => e
    warn "[FINALIZER_FSYNC_ERR] #{e.class}: #{e.message}"
  end
  log_metrics_file_size(path, label: "FINALIZER") if defined?(log_metrics_file_size)
  puts "[FINALIZER] ✅ metrics file written safely at exit → #{path}"

  # Mirror to preflight path if present
  boot_path = ENV["METRICS_BOOT_PATH"].to_s
  if !boot_path.empty? && boot_path != path
    begin
      FileUtils.mkdir_p(File.dirname(boot_path)) rescue nil
      FileUtils.cp(path, boot_path)
      puts "[BOT_METRICS] 🔁 mirrored metrics to preflight path → #{boot_path}"
    rescue => e
      warn "[BOT_METRICS] mirror failed: #{e.class}: #{e.message}"
    end
  end
end

# Install once; avoid control-flow keywords in the at_exit block itself
$__metrics_finalizer_installed ||= begin
  at_exit do
    begin
      write_metrics_finalizer! unless ENV["METRICS_CSV_ALREADY_WRITTEN"] == "1"
    rescue => e
      warn "[FINALIZER_ERR] #{e.class}: #{e.message}\n" +
           (e.backtrace || [])[0,12].map { |l| "  • #{l}" }.join("\n")
    end
  end
  true
end
