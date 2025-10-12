# typed: false
# frozen_string_literal: true

require "pry"
require "json"
require "active_support/all"

pwd = Dir.pwd
raise "Cannot find /tmp directory" unless File.exist?("./tmp")

##### HELPERS #####
def kebab_case(str)
  return if str.nil?
  str = str.gsub(/([a-z])([A-Z])/, '\1-\2').downcase
  str.gsub("_", "-")
end

def camel_case(str)
  return if str.nil?
  str.split("-").map(&:capitalize).join
end

def green(str)
  "\e[32m#{str}\e[0m"
end

def yellow(str)
  "\e[33m#{str}\e[0m"
end

def red(str)
  "\e[31m#{str}\e[0m"
end

##### NORMAL TASKS #####
class AutoTask
  def self.tasks
    result = { "watcher" => WatcherTask.new }
    (AutoTask.subclasses - [WatcherTask]).each do |klass|
      task = klass.new
      result[task.task_name] = task
    end
    file_dir = File.dirname(__FILE__)
    config = JSON.parse(File.read(File.join(file_dir, "my_daemon.json")))
    config.each do |task_config|
      task_config = task_config.transform_keys(&:to_sym)
      result[task_config[:name]] = AutoTask.new(**task_config)
    end
    result
  end

  attr_reader :command, :trigger, :dependencies

  def initialize(name:, command:, trigger:, dependencies: [])
    @name = name
    @command = command
    @trigger = trigger
    @dependencies = dependencies
  end

  def run_command
    puts "#{Time.now} Running #{task_name}"
    system(command)
  end

  def start
    if ["running", "starting", "idle"].include?(status)
      puts "#{@name} is already running"
    else
      set_state(pid: nil, status: "idle")
    end
  end

  def background_fork
    fork do
      Process.daemon(true)
      set_state(pid: Process.pid, status: "running")
      $stdout.reopen(log_file, "a")
      $stderr.reopen(log_file, "a")
      $stdout.sync = true
      $stderr.sync = true
      yield
      set_state(pid: nil, status: "idle")
    end
  end

  def set_state(**state)
    state = state.transform_keys(&:to_s)
    state = get_state.merge(state)
    File.open(json_file, "w") { |f| f.puts JSON.dump(state) }
  end

  def stop
    state = get_state
    pid = state["pid"]
    Process.kill("TERM", pid) if pid
  rescue Errno::ESRCH
    puts "AutoTask is not running"
  ensure
    File.delete(json_file) if File.exist?(json_file)
  end

  def get_state
    JSON.parse(File.read(json_file))
  rescue Errno::ENOENT
    {}
  end

  def task_name
    kebab_case(@name)
  end

  def log_file
    "./tmp/#{@name}.log"
  end

  def json_file
    "./tmp/#{@name}.json"
  end

  def status(color: false)
    state = get_state
    if state.empty?
      return color ? red("stopped") : "stopped"
    end
    pid = state["pid"]
    Process.kill(0, pid) if pid
    status = state["status"]
    color ? green(status) : status
  rescue Errno::ESRCH
    set_state(pid: nil, status: "stopped")
    color ? red("stopped") : "stopped"
  end
end

##### WATCHER #####
class WatcherTask < AutoTask
  def initialize
    super(name: "watcher", command: nil, trigger: "git-checkout")
  end

  def start
    if status == "running"
      puts "watcher is already running"
    else
      background_fork do
        loop do
          new_branch = `git rev-parse --abbrev-ref HEAD`.strip
          self.class.tasks.each do |_, task|
            next unless task.trigger == "git-checkout"
            state = task.get_state
            next unless state["last_branch"] != new_branch && state["status"] == "idle"

            busy = task.dependencies.map do |dependency_name|
              dependency = AutoTask.tasks[dependency_name]
              dependency.status == "running" || dependency.get_state["last_branch"] != new_branch
            end.any?
            puts "#{task.task_name} is waiting for another task" if busy
            next if busy

            puts "Branch changed. Running #{task.task_name}"
            task.set_state(last_branch: new_branch)
            task.background_fork do
              task.run_command
            end
          end
          sleep 5
        end
      end
    end
  end
end


##### CLI #####
command = ARGV[0]
task_name = kebab_case(ARGV[1])
if command == "start"
  if task_name.nil?
    puts "Usage: ruby my_daemon.rb start TASK_NAME|all"
    puts "Available tasks:"
    AutoTask.tasks.each do |name, task|
      puts name
    end
    exit
  elsif task_name == "all"
    AutoTask.tasks.each do |name, task|
      task.start
    end
  else
    AutoTask.tasks[task_name].start
  end
elsif command == "stop"
  if task_name.nil?
    puts "Usage: ruby my_daemon.rb stop TASK_NAME|all"
    puts "Available tasks:"
    AutoTask.tasks.each do |name, task|
      puts name
    end
    exit
  elsif task_name == "all"
    AutoTask.tasks.each do |name, task|
      task.stop
    end
  else
    AutoTask.tasks[task_name].stop
  end
elsif command == "tail"
  if task_name.nil?
    puts "Usage: ruby my_daemon.rb tail TASK_NAME"
    puts "Available tasks:"
    AutoTask.tasks.each do |name, task|
      puts name
    end
    exit
  else
    system("tail -n 200 -f #{AutoTask.tasks[task_name].log_file}")
  end
else
  puts "Usage: ruby my_daemon.rb start|stop|tail"
  puts "Status:"
  AutoTask.tasks.each do |name, task|
    puts "#{name}: #{task.status(color: true)}"
  end
end
