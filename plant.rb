#!/usr/bin/env ruby

require 'set'
require 'optparse'
require 'json'

class SeatingChart
  def initialize(options)
    @lock = Mutex.new
    @best = {iter: -1, array: nil, students: nil, deviation: 10}

    @count = options[:students]
    @length = options[:rounds]

    @output = options[:format]
    @out_file = options[:output]
    @input = options[:input]
    @names = options[:names]

    @options = options
  end

  def eol
    create_names(@count)
    b = @best
    STDERR.puts "Best Results: #{b[:iter] + 1}"
    print_grid(b[:students])
    STDERR.puts "Distribution:"
    counts = Hash.new(0)
    b[:students].each {|row| row.each {|cell| counts[cell] += 1}}
    counts.delete(99)
    counts = Hash[counts.map{|k, v| [k, v / 2]}]
    counts.each do |o|
      STDERR.puts "  %2d => %d" % o
    end
    STDERR.puts "Standard Deviation: #{b[:deviation].round 3}"
    print_out(b[:array])
  end

  def start
    if @input
      data = File.open(@input, 'r'){|f| JSON.parse(f.read)}
      create_names(data.first.flatten.length)
      print_out(data)
    else
      run
    end
  end

  def run
    4.times.map do
      Thread.new do
        loop do
          catch :died do
            students = Array.new(@count) do |i|
              x = Array.new(@count, 0)
              x[i] = 99
              x
            end
            all_groups = []
            max = 1
            @length.times do |iter|
              groups = []
              used = Set.new
              index = 0
              g3 = (4 - @count % 4) % 4
              total = (@count / 4.0).ceil
              if iter % (total - 1) == 0 #&& iter < @count / 4 || iter % (@count / 4) == 0 && iter > @count / 4
                max += 1
              end
              total.times do |round|
                indexes = @count.times.reject{|i| used.include?(i)}
                index = indexes.delete(indexes.sample)
                group = [index]
                used << index
                (total - g3 <= round ? 2 : 3).times do
                  valid = nil
                  1.upto(max) do |n|
                    valid = indexes.reject{|i| group.inject(false){|m,o| m || students[o][i] >= n}}
                    break if valid.length > 0
                  end
                  throw :died if valid.length < 1
                  local_index = valid.sample
                  indexes.delete(local_index)
                  used << local_index
                  group.each do |i|
                    students[i][local_index] += 1
                    students[local_index][i] += 1
                  end
                  group << local_index
                end
                groups << group
              end
              all_groups << groups
              std_dev = std_deviation(students)
              @lock.synchronize do
                if iter > @best[:iter] || iter == @best[:iter] && std_dev < @best[:deviation]
                  STDERR.puts "#{Time.now} | Best: %2d, STDDEV: #{std_dev.round 4}" % iter
                  @best = {iter: iter, array: all_groups, students: students, deviation: std_dev}
                end
              end
            end
          end
        end
      end
    end.map(&:join)
  end

  private

  def print_grid(grid)
    STDERR.print '   '
    0.upto(grid.length - 1){|n| STDERR.print ' %2d' % n}
    STDERR.puts
    grid.each_with_index do |line, num|
      STDERR.print ' %2d' % num
      out = ''.dup
      line.each {|x| out << ('%3d' % x)}
      STDERR.puts out
    end
  end

  def std_deviation(students)
    counts = Hash.new(0)
    students.each {|row| row.each {|cell| counts[cell] += 1}}
    counts.delete(99)
    counts = Hash[counts.map{|k, v| [k, v / 2]}]
    number = counts.values.inject(:+)
    mean = counts.inject(0.0) {|m,o| m + o[0] * o[1] } / number
    Math.sqrt(counts.inject(0.0) {|m,o| m + o[1] * ((o[0] - mean) ** 2) / number })
  end

  def print_out(data)
    out = @out_file && @out_file != '-' && File.open(@out_file, 'w') || STDOUT
    case @output
    when :grouped
      longest = @names.inject(0){|m,o| [m, o.length, (data.first.length / 10.0).ceil + 6].max}
      data.each_with_index do |line, index|
        unless index == 0
          out.puts '---------------------------------------'
          out.puts
        end
        out.puts "Groupings ##{index + 1}\n\n"
        formatting = "| %-#{longest}s |"
        line.each_slice(4).each_with_index do |people, index|
          out.puts(people.length.times.map do |t|
            "| Group %-#{longest - 6}d |" % (index * 4 + t + 1)
          end.join(' '))
          people.delete_at(0).zip(*people) do |row|
            output = ""
            row.each_with_index do |num, i|
              output << ' ' unless i == 0
              output << (formatting % @names[num]) unless num.nil?
            end
            out.puts output
          end
          out.puts
        end
      end
    when :json
      out.puts JSON.dump(data)
    when :list
      data.each_with_index do |line, index|
        unless index == 0
          out.puts '---------------------------------------'
          out.puts
        end
        out.puts "Groupings ##{index + 1}\n\n"
        line.each do |row|
          row.each do |num|
            out.puts "  #{@names[num]}"
          end
          out.puts
        end
      end
    end
  ensure
    out.close unless out == STDOUT
  end

  def create_names(count)
    @names ||= Array.new(count) {|i| (i + 1).to_s}
  end
end

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: seating.rb [options]"

  opts.on("-s", "--students COUNT", Integer, "Number of students") do |s|
    options[:students] = s
  end

  opts.on("-n", "--names FILE", String, "File containing names. One per line. (This overrides student count)") do |f|
    options[:names] = File.open(f, 'r'){|f| f.read.split("\n")}
    options[:students] = options[:names].length
  end

  opts.on("-r", "--rounds ROUNDS", Integer, "Number of rounds to perform") do |r|
    options[:rounds] = r
  end

  opts.on("-o", "--output FILE", String, "File to output to (defaults to stdout)") do |f|
    options[:format] = :json if f.include?('.json')
    options[:output] = f
  end

  options[:format] ||= :list
  opts.on("-f", "--format FORMAT", [:json, :grouped, :list], "Format to output data") do |f|
    options[:format] = f
  end

  opts.on("-i", "--input FILE", String, "Will change format of a JSON file") do |f|
    options[:input] = f
  end

  opts.on("-h", "--help", "Prints this help") do
    puts opts
    exit
  end
end.parse!

chart = SeatingChart.new(options)
Signal.trap("INT") {
  chart.eol
  exit
}

# Trap `Kill`
Signal.trap("TERM") {
  chart.eol
  exit
}
chart.start
