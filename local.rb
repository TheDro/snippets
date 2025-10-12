# typed: false
# frozen_string_literal: true

# All of your initializers would be included in this file

module RubyWarningsPatch
  def warn(message)
    # no op
  end
end

Warning.singleton_class.prepend(RubyWarningsPatch)

class Object
  def my_methods
    methods - Object.methods
  end
end

if Object.const_defined?("ActiveRecordQueryTrace") && Rails.env.local?
  ActiveRecordQueryTrace.enabled = false
  ActiveRecordQueryTrace.lines = 20
  ActiveRecordQueryTrace.level = :full # :app or :full
end


if Object.const_defined?("HttpLog") && Rails.env.development?
  HttpLog.configure do |config|
    config.enabled = false
    config.logger = Rails.logger
    config.log_headers = true
    # config.json_log = true
  end
end

class CurrentQueries < ActiveSupport::CurrentAttributes
  attribute :query_stats

  def self.colored_sql(sql)
    case sql
    when /\A\s*rollback/mi
      sql.red
    when /select .*for update/mi, /\A\s*lock/mi
      sql.white
    when /\A\s*select/i
      sql.blue
    when /\A\s*insert/i
      sql.green
    when /\A\s*update/i
      sql.yellow
    when /\A\s*delete/i
      sql.red
    when /transaction\s*\Z/i
      sql.cyan
    else
      sql.magenta
    end
  end
end

if Rails.env.development?
  ActiveRecord::LogSubscriber.detach_from(:active_record)

  $backtrace_cleaner = ActiveSupport::BacktraceCleaner.new
  $backtrace_cleaner.add_silencer { |line| line =~ /local\.rb/ }

  def log_query_source
    source = query_source_location
    if source
      logger.debug("  ↳ #{source}")
    end
  end

  if Thread.respond_to?(:each_caller_location)
    def query_source_location
      Thread.each_caller_location do |location|
        frame = $backtrace_cleaner.clean_frame(location)
        return frame if frame
      end
      nil
    end
  else
    def query_source_location
      $backtrace_cleaner.clean(caller(1).lazy).first
    end
  end

  ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, start, finish, _id, payload|
    next if payload[:name] == "SCHEMA"
    CurrentQueries.query_stats ||= {}
    CurrentQueries.query_stats[payload[:name]] ||= []
    CurrentQueries.query_stats[payload[:name]] << payload unless payload[:cached]

    duration_ms = ((finish - start) * 1000).round(1)
    count = CurrentQueries.query_stats[payload[:name]].count
    name = "#{payload[:name]} (#{duration_ms}ms)[#{count}]"
    name = "CACHE #{name}" if payload[:cached]
    name = if (duration_ms > 100 || count >= 5) && !payload[:cached]
      name.yellow
    else
      name.cyan
    end
    sql = payload[:cached] ? "" : payload[:sql]
    sql = CurrentQueries.colored_sql(sql)

    Rails.logger.debug {
      "  #{name} #{sql}"
    }
    source = query_source_location
    if source
      Rails.logger.debug { "  ↳ #{source}" }
    end
  end

  ActiveSupport::Notifications.subscribe("process_action.action_controller") do |_name, _start, _finish, _id, payload|
    CurrentQueries.query_stats = {}
  end
end


class SimpleDebouncer
  def initialize(delay, &block)
    @delay = delay
    @block = block
    @timer = nil
    @mutex = Mutex.new
  end

  def call(*args)
    @mutex.synchronize do
      @timer&.kill
      @timer = Thread.new do
        sleep(@delay)
        @block.call(*args)
      end
    end
  end

  def cancel
    @mutex.synchronize do
      @timer&.kill
      @timer = nil
    end
  end
end

$modified_files = Set.new
module ListenerPatch
  @@debouncer = nil
  # $modified_files = Set.new
  def changed(modified, added, removed)
    puts "Modified: #{modified.inspect}"
    $modified_files.merge(modified)
    @@debouncer ||= SimpleDebouncer.new(0.5) do
      puts "Reloading the files"
      Rails.application.reloader.reload!
      $modified_files.to_a.each do |file|
        Rails.application.autoloaders.main.load_file(file)
      end
      puts "Done reloading"
      # $modified_files = Set.new
    end
    @@debouncer.call
    super
  end
end

Rails.autoloaders.log!
Rails.autoloaders.main.on_load do |cpath, value, abspath|
  # puts "#{cpath} / #{value} / #{abspath}"
  $modified_files.add(abspath) if abspath.end_with?(".rb")
end

ActiveSupport::EventedFileUpdateChecker::Core.prepend(ListenerPatch)