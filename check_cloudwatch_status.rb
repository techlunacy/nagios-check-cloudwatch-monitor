#!/bin/bash ruby
## gem install fog awesome_print recursive-open-struct
%w[rubygems bundler/setup optparse fog ap base64 openssl recursive_open_struct].each { |f| require f }
class CheckCloudwatchStatus
  # define static values
  EC2_STATUS_CODE_PENDING = 0
  EC2_STATUS_CODE_RUNNING = 16
  EC2_STATUS_CODE_TERMINATING = 32
  EC2_STATUS_CODE_STOPPING  = 64
  EC2_STATUS_CODE_STOPPED = 80

  EC2_STATUS_NAME_PENDING	= "pending"
  EC2_STATUS_NAME_RUNNING	= "running"
  EC2_STATUS_NAME_TERMINATING = "terminating"
  EC2_STATUS_NAME_STOPPING = "stopping"
  EC2_STATUS_NAME_STOPPED = "stopped"

  EC2_STATE_ENABLED = "enabled"
  EC2_STATE_PENDING = "pending"
  EC2_STATE_DISABLING = "disabling"

  AWS_NAMESPACE_EC2 = "AWS/EC2"
  AWS_NAMESPACE_EBS = "AWS/EBS"
  AWS_NAMESPACE_ELB = "AWS/ELB"
  AWS_NAMESPACE_RDS = "AWS/RDS"

  NAGIOS_CODE_OK = 0		# UP
  NAGIOS_CODE_WARNING = 1		# UP or DOWN/UNREACHABLE*
  NAGIOS_CODE_CRITICAL = 2	# DOWN/UNREACHABLE
  NAGIOS_CODE_UNKNOWN = 3		# DOWN/UNREACHABLE
  NAGIOS_OUTPUT_SEPARATOR = "|"

  CLOUDWATCH_TIMER = 600
  CLOUDWATCH_DETAILED_TIMER = 180
  CLOUDWATCH_PERIODE = 60

  # specify the options we accept and initialize and the option parser
  def set_threshold( arg_str )
    arg = String.new( arg_str )
    values = []
    if (arg =~ /^[0-9]+$/)
      values[0] = 0
      values[1] = arg.to_f()
    elsif (arg =~ /^[0-9]+:$/)
      values[0] = arg.gsub!( /:/, '' ).to_f()
      values[1] = (+1.0/0.0)	# +Infinity
    elsif (arg =~ /^~:[0-9]+$/)
      puts "DEBUG: REGEXP ^~:[0-9]+$"
      arg.gsub!( /~/, '' )
      values[0] = (-1.0/0.0)	# -Infinity
      values[1] = arg.gsub!( /:/, '' ).to_f()
    elsif (arg =~ /^[0-9]+:[0-9]+$/)
      values_str = arg.split( /:/ )
      values[0] = values_str[0].to_f()
      values[1] = values_str[1].to_f()
    elsif (arg =~ /^@[0-9]+:[0-9]+$/)
      arg.gsub!( /@/, '' )
      values_str = arg.split( /:/ )
      values_str.reverse!()
      values[0] = values_str[0].to_f()
      values[1] = values_str[1].to_f()
    end
    return values
  end

  def has_statistic_crossed_threshold(statistic, threshold_values)
    if ((threshold_values[0]).to_f() < (threshold_values[1]).to_f()) && 
      (statistic < (threshold_values[0]).to_f() || statistic > (threshold_values[1]).to_f())
      return true
    elsif ((threshold_values[0]).to_f() > (threshold_values[1]).to_f()) &&
      (statistic < (threshold_values[0]).to_f() && statistic > (threshold_values[1]).to_f())
      return true
    end
    return false
  end

  def check_threshold( arg_str, warn_values, crit_values )
    statistic = arg_str.to_f()  
    return NAGIOS_CODE_CRITICAL if has_statistic_crossed_threshold(statistic, crit_values)
    return NAGIOS_CODE_WARNING if has_statistic_crossed_threshold(statistic, warn_values)
    return NAGIOS_CODE_OK
  end

  def logger(value)
    ap value if @verbose  == 1
  end

  def parse_options(*args)
    OptionParser.new do |opts|
      opts.banner = "Usage: check_cloudwatch_status.rb [options]"
      opts.on("-v", "--verbose", "Run verbosely") do 
        @verbose = 1
      end
      opts.on("-h", "--help", "Help") do
        puts opts
        exit 0
      end
      opts.on("--region", "-r REGION", "aws region") do |opt|
        @region = opt
      end
      opts.on("--instance_id", "-i INSTANCE", "instance id") do |opt|
        @instance_id = opt
      end
      opts.on("--access_id", "-a ACCESS_ID", "aws access id") do |opt|
        @access_key_id = opt
      end
      opts.on("--access_secret", "-s ACCESS_SECRET", "aws secret") do |opt|
        @secret_access_key = opt
      end
      opts.on("--statistic STATISTIC", "statistic ['Minimum','Maximum','Average', 'Sum','SampleCount']") do |opt|
        @statistic = opt
      end
      opts.on("--type", "-t TYPE", "ec2 elb rds") do |opt|
        @metric_type = opt
        case opt
          when 'ec2'
            @namespace = AWS_NAMESPACE_EC2
            @identifier_field_name = "InstanceId"
          when 'elb'
            @namespace = AWS_NAMESPACE_ELB
            @identifier_field_name = "LoadBalancerName"
          when 'rds'
            @namespace = AWS_NAMESPACE_RDS
            @identifier_field_name = "DBInstanceIdentifier"
          end
      end        
      opts.on("--metric", "-m METRIC", "metric") do |opt|
        @metric = opt
      end
      opts.on("--warning", "-w WARNING", "warning level") do |opt|
        @warning_values = set_threshold( opt )
      end
      opts.on("--critical", "-c CRITICAL", "critical level") do |opt|
        @critical_values = set_threshold( opt )
      end
    end.parse!

    if (@instance_id.empty? || @region.empty? || @access_key_id.empty? || @secret_access_key.empty? || @region.empty? || @metric.empty?)
      puts `ruby check_cloudwatch_status.rb --help`
    end

    logger  "** Launching AWS status retrieval on instance ID: #{@instance_id}"
    logger  "Instance Type: #{@metric_type}"
    logger  "Amazon Region: #{@region}"
    logger  "Warning values: #{@warning_values.inspect}"
    logger  "Critical values: #{@critical_values.inspect}"
  end

  def credentials
    {
      :region                 => @region,
      :aws_access_key_id        => @access_key_id,
      :aws_secret_access_key    => @secret_access_key
    }
  end

  def get_instance
    begin
      response = case @namespace
        when AWS_NAMESPACE_EC2
          Fog::Compute::AWS.new(credentials).describe_instances('instance-id' => @instance_id)
        when AWS_NAMESPACE_RDS
          Fog::AWS::RDS.new(credentials).describe_db_instances(@instance_id)
        when AWS_NAMESPACE_ELB
          Fog::AWS::ELB.new(credentials).describe_load_balancers(@identifier_field_name => @instance_id)
      end
      RecursiveOpenStruct.new(response.body)
    rescue Exception => e
      puts  "Error occured while trying to connect to AWS Endpoint: " + e.to_s
      exit NAGIOS_CODE_CRITICAL
    end
  end

  def get_state(instance)
    begin
      case @namespace
        when AWS_NAMESPACE_EC2
          #EC2 
          instance_item = RecursiveOpenStruct.new(instance.reservationSet[0]["instancesSet"][0])
          state_name = instance_item.instanceState.name
          # Check if Cloudwatch monitoring is enabled
          cloudwatch_enabled = instance_item.monitoring.state
        when AWS_NAMESPACE_RDS
          if instance.DescribeDBInstancesResult.DBInstances.nil? || instance.DescribeDBInstancesResult.DBInstances.empty?
            puts "Error occured while retrieving RDS instance: no instance found for ID #{@instance_id}" 
          else
            db_instance = RecursiveOpenStruct.new(instance.DescribeDBInstancesResult.DBInstances[0])

            state_name = EC2_STATUS_NAME_RUNNING if db_instance.DBInstanceStatus.eql?("available")
            cloudwatch_enabled = EC2_STATE_ENABLED
          end
        when AWS_NAMESPACE_ELB
          #ELB
          if instance.DescribeLoadBalancersResult.LoadBalancerDescriptions.nil? || instance.DescribeLoadBalancersResult.LoadBalancerDescriptions.empty?
            puts "Error occured while retrieving ELB: no ELB found for ID #{instance_id}"
            #exit NAGIOS_CODE_CRITICAL
          else
            instances = RecursiveOpenStruct.new(instance.DescribeLoadBalancersResult.LoadBalancerDescriptions[0]).Instances
            if !instances.nil? || !instances.empty?
              state_name = EC2_STATUS_NAME_RUNNING
            end
              cloudwatch_enabled = EC2_STATE_ENABLED
          end
        end
        [cloudwatch_enabled, state_name]
    rescue Exception => e
      puts  "Error occured while trying to retrieve AWS instance: " + e.to_s
      exit NAGIOS_CODE_CRITICAL
    end
  end

  def nagios_code(state)
    case state
      when EC2_STATUS_NAME_PENDING
        NAGIOS_CODE_WARNING
      when EC2_STATUS_NAME_RUNNING
        NAGIOS_CODE_OK
      when EC2_STATUS_NAME_STOPPING
        NAGIOS_CODE_WARNING
      when EC2_STATUS_NAME_STOPPED
        NAGIOS_CODE_CRITICAL
      else
        NAGIOS_CODE_UNKNOWN
    end
  end

  def get_statistics
    begin
      cloudwatch = Fog::AWS::CloudWatch.new(credentials)
    rescue Exception => e
       puts "Error occured while trying to connect to CloudWatch server: " + e.to_s
      exit NAGIOS_CODE_CRITICAL
    end

    # interesting debug
    logger  "CloudWatch:"
    logger  cloudwatch

    begin
      ## ['Minimum','Maximum','Sum','SampleCount','Average']
      cloudwatch_metrics_stats = RecursiveOpenStruct.new(cloudwatch.get_metric_statistics({'Statistics' => ['Minimum','Maximum','Average', 'Sum','SampleCount'], 'StartTime' => (Time.now-300).iso8601, 'EndTime' => Time.now.iso8601, 'Period' => 60, 'MetricName' => @metric, 'Namespace' => @namespace, 'Dimensions' => [{'Name' => @identifier_field_name, 'Value' => @instance_id}]}).body)
    rescue Exception => e
      puts  "Error occured while trying to retrieve CloudWatch metrics statistics: " + e.to_s
      exit NAGIOS_CODE_CRITICAL
    end

    # interesting debug
    logger  "CloudWatch Metrics Statistics:"
    logger cloudwatch_metrics_stats
    cloudwatch_metrics_stats
  end

  def initialize(*args)
    @instance_id = ''
    @access_key_id = ''
    @secret_access_key = ''
    @region = ''
    @metric = ''
    @metric_type = ''
    @verbose = 0
    @warning_values = []
    @critical_values = []
    @cloudwatch_timer = CLOUDWATCH_TIMER
    @cloudwatch_period = CLOUDWATCH_PERIODE
    @namespace = AWS_NAMESPACE_EC2
    @available = ''
    @identifier_field_name = ''     

    parse_options(args)
    instance = get_instance

    logger  "AWS Instance:#{instance}"


    cloudwatch_enabled,state_name = get_state(instance)
    return_code = nagios_code(state_name)

    if return_code != NAGIOS_CODE_OK
      logger  "Instance #{@instance_id} is not running, so real-time monitoring is not available"
      exit return_code
    elsif !(cloudwatch_enabled == EC2_STATE_ENABLED)
      logger  "CloudWatch Detailed Monitoring is enabled for Instance #{@instance_id}"
      cloudwatch_timer = CLOUDWATCH_DETAILED_TIMER
    end

    cloudwatch_metrics_stats = get_statistics

    average = "NaN"
    maximum = "NaN"
    minimum = "NaN"
    if (cloudwatch_metrics_stats.nil? || cloudwatch_metrics_stats.empty?)
      return_code = NAGIOS_CODE_WARNING
    elsif !(cloudwatch_metrics_stats.GetMetricStatisticsResult.Datapoints.nil? || cloudwatch_metrics_stats.GetMetricStatisticsResult.Datapoints.empty?)
      data_point = cloudwatch_metrics_stats.GetMetricStatisticsResult.Datapoints[0]
      average = sprintf( "%.2f", data_point["Average"])
      maximum = sprintf( "%.2f", data_point["Maximum"] )
      minimum = sprintf( "%.2f", data_point["Minimum"] )
      stat = sprintf( "%.2f", data_point[@statistic] )
      return_code = NAGIOS_CODE_OK
      # check for threshold and ranges
      return_code = check_threshold( stat, @warning_values, @critical_values )
    else
      return_code = NAGIOS_CODE_UNKNOWN
    end
    # print SERVICEOUTPUT
    service_output = "CloudWatch Metric: #{@metric}, Average: #{average}, Maximum: #{maximum}, Minimum: #{minimum}, #{@statistic}: #{stat}"

    # print SERVICEPERFDATA
    service_perfdata = "metric_average=#{average} metric_maximum=#{maximum} metric_minimum=#{minimum}, metric_#{@statistic.downcase}=#{stat}"

    # output
    logger  "#{service_output}|#{service_perfdata}"
    puts  "#{service_output}|#{service_perfdata}"
    exit return_code
  end
end
CheckCloudwatchStatus.new(ARGV)
