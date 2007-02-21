# antwrap
#
# Copyright Caleb Powell 2007
#
# Licensed under the LGPL, see the file COPYING in the distribution
#
require 'fileutils'
require 'logger'
require 'java'

module ApacheAnt
  include_class "org.apache.tools.ant.UnknownElement"
  include_class "org.apache.tools.ant.RuntimeConfigurable"
  include_class "org.apache.tools.ant.Project"
  include_class "org.apache.tools.ant.DefaultLogger"
  include_class "org.apache.tools.ant.Target"
  include_class "org.apache.tools.ant.Main"
end

module JavaLang
  include_class "java.lang.System"
end

class AntTask
  private
  @@task_stack = Array.new
  attr_reader :unknown_element, :project, :taskname, :logger, :executed
  
  public  
  def initialize(taskname, antProject, attributes, proc)
    taskname = taskname[1, taskname.length-1] if taskname[0,1] == "_"
    @logger = antProject.logger
    @logger.debug("AntTask: #{taskname}")
    @taskname = taskname
    @project_wrapper = antProject
    @project = antProject.project()
    @logger.debug(@project)
    @unknown_element = create_unknown_element(@project, taskname)
    
    addAttributes(attributes)
    
    if proc
      @logger.debug("task_stack.push #{taskname} >> #{@@task_stack}") 
      @@task_stack.push self
      
      singleton_class = class << proc; self; end
      singleton_class.module_eval{
        def method_missing(m, *a, &proc)
          @@task_stack.last().send(m, *a, &proc)
        end
      }
      proc.instance_eval &proc
      @@task_stack.pop 
    end
    
  end
  
  def create_unknown_element(project, taskname)
    
    unknown_element = ApacheAnt::UnknownElement.new(taskname)
    unknown_element.project= project
    unknown_element.owningTarget= ApacheAnt::Target.new()
    unknown_element.taskName= taskname
    
    if(@project_wrapper.ant_version >= 1.6)
      unknown_element.taskType= taskname
      unknown_element.namespace= ''
      unknown_element.QName= taskname
    end
    
    return unknown_element
    
  end
  
  def addAttributes(attributes)
    
    return if attributes == nil
    
    wrapper = ApacheAnt::RuntimeConfigurable.new(@unknown_element, @unknown_element.getTaskName());
    outer_func = lambda{ |key, val, tfunc|  key == 'pcdata' ? wrapper.addText(val) : tfunc.call(key, val) }
    
    if(@project_wrapper.ant_version >= 1.6)
      attributes.each do |key, val| 
        outer_func.call(key.to_s, val, lambda{|k,v| wrapper.setAttribute(k, val)}) 
      end
    else  
      @unknown_element.setRuntimeConfigurableWrapper(wrapper)
      attribute_list = org.xml.sax.helpers.AttributeListImpl.new()
      attributes.each do |key, val| 
        outer_func.call(key.to_s, val, lambda{|k,v| attribute_list.addAttribute(k, 'CDATA', v)})
      end
      wrapper.setAttributes(attribute_list)
    end
    
  end
  
  def method_missing(sym, *args)
    begin
      @logger.debug("AntTask.method_missing sym[#{sym.to_s}]")
      task = AntTask.new(sym.to_s, @project_wrapper, args[0], block_given? ? Proc.new : nil)
      self.add(task)
    rescue StandardError
      @logger.error("AntTask.method_missing error:" + $!)
    end
  end  
  
  def add(child)
    @logger.debug("adding child[#{child.taskname}] to [#{@taskname}]")
    @unknown_element.addChild(child.unknown_element())
    @unknown_element.getRuntimeConfigurableWrapper().addChild(child.unknown_element().getRuntimeConfigurableWrapper())
  end
  
  def execute
    @unknown_element.maybeConfigure
    @unknown_element.execute
    @executed = true
  end
  
end

class AntProject
  
  attr :project, false
  attr :version, false
  attr :ant_version, true
  attr :declarative, true
  attr :logger, true
  
  # Create an AntProject. Parameters are specified via a hash:
  # :name=><em>project_name</em>
  #   -A String indicating the name of this project. Corresponds to the 
  #   'name' attrbute on an Ant project.  
  # :basedir=><em>project_basedir</em>
  #   -A String indicating the basedir of this project. Corresponds to the 'basedir' attribute 
  #   on an Ant project.  
  # :declarative=><em>declarative_mode</em>
  #   -A boolean value indicating wether Ant tasks created by this project instance should 
  #   have their execute() method invoked during their creation. For example, with 
  #   the option :declarative=>true the following task would execute; 
  #   @antProject.echo(:message => "An Echo Task")
  #   However, with the option :declarative=>false, the programmer is required to execute the 
  #   task explicitly; 
  #   echoTask = @antProject.echo(:message => "An Echo Task")
  #   echoTask.execute()
  #   Default value is <em>true</em>.
  # :logger=><em>Logger</em>
  #   -A Logger instance. Defaults to Logger.new(STDOUT)
  # :loglevel=><em>The level to set the logger to</em>
  #   -Defaults to Logger::ERROR
  def initialize(options=Hash.new)
    @project= ApacheAnt::Project.new
    @project.name= options[:name] || ''
    @project.default= ''
    @project.basedir= options[:basedir] || '.'
    @project.init
    self.declarative= options[:declarative] || true      
    default_logger = ApacheAnt::DefaultLogger.new
    default_logger.messageOutputLevel= 2
    default_logger.outputPrintStream= JavaLang::System.out
    default_logger.errorPrintStream= JavaLang::System.err
    default_logger.emacsMode= false
    @project.addBuildListener default_logger
    @version = ApacheAnt::Main.getAntVersion
    @ant_version = @version[/\d\.\d\.\d/].to_f
    @logger = options[:logger] || Logger.new(STDOUT)
    @logger.level = options[:loglevel] || Logger::ERROR
    @logger.debug(@version)
  end
  
  def create_task(taskname, attributes, proc)
    @logger.debug("Antproject.create_task.taskname = " + taskname)
    @logger.debug("Antproject.create_task.attributes = " + attributes.to_s)
    
    task = AntTask.new(taskname, self, attributes, proc)
    task.execute if declarative
    return task
  end
  
  def method_missing(sym, *args)
    begin
      @logger.debug("AntProject.method_missing sym[#{sym.to_s}]")
      return create_task(sym.to_s, args[0], block_given? ? Proc.new : nil)
    rescue
      @logger.error("Error instantiating task[#{sym.to_s}]" + $!)
    end
  end
  
  def name()
    return @project.name
  end
  
  def basedir()
    return @project.getBaseDir().getAbsolutePath();
  end
  
  #overridden. 'mkdir' conflicts wth the rake library.
  def mkdir(attributes)
    create_task('mkdir', attributes, (block_given? ? Proc.new : nil))
  end  
  
  #overridden. 'copy' conflicts wth the rake library.
  def copy(attributes)
    create_task('copy', attributes, (block_given? ? Proc.new : nil))
  end  
  
  #overridden. 'java' conflicts wth the JRuby library.
  def jvm(attributes=Hash.new)
    create_task('java', attributes, (block_given? ? Proc.new : nil))
  end  
  
end