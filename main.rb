require 'open3'
require 'pathname'
require 'xcodeproj'
require 'json'
require 'net/http'
require 'plist'
require 'English'
require 'fileutils'
require 'diff/lcs'

def env_has_key(key)
  value = ENV[key]
  if !value.nil? && value != ''
    return value.start_with?('$') ? ENV[value[1..-1]] : value
  else
    abort("Missing #{key}.")
  end
end

def get_env(key)
  value = ENV[key]
  if !value.nil? && value != ''
   return value start_with?('$') ? ENV[value[1..-1]] : value
  else
    return nil
  end
end

def get_env_variable(key)
  ENV[key].nil? || ENV[key] == '' ? nil : ENV[key]
end

# .xcodeproj dosyasının yolunu al
def xcode_project_file
  repository_path = env_has_key('AC_REPOSITORY_DIR')
  project_path = env_has_key('AC_PROJECT_PATH')
  project_path = (Pathname.new repository_path).join(Pathname.new(project_path))
  puts "Proje yolu: #{project_path}"
  project_directory = File.dirname(project_path)
  puts "Proje dizini: #{project_directory}"
  if File.extname(project_path) == '.xcworkspace' 
    Dir[File.join(project_directory, '*.xcodeproj')][0]
  else
    project_path
  end
end

# def get_value_from_build_settings!(target, variable, configuration = nil)
#   target.build_configurations.each do |config|
#       if configuration.nil? || config.name == configuration
#         value = config.resolve_build_setting(variable)
#         return value if value
#       end
#   end
# end

def get_value_from_build_settings!(target, variable, configuration = nil)
  values = {}
  target.build_configurations.each do |config|
    if configuration.nil? || config.name == configuration
      config.build_settings.each do |key, value|
        if key.start_with?(variable)
          values[key] = value
        end
      end
    end
  end
  values.each do |key, value|
    puts "#{key}: #{value}"
  end
  values
end

def runnable_target?(target)
    product_reference = target.product_reference
    return false unless product_reference
    product_reference.path.end_with?('.app', '.appex')
end

def update_target(params,target,key,value,variable)
    # Update Xcode config if Xcode is generating the plist
    target.build_configurations.each do |config|
      if config.build_settings['GENERATE_INFOPLIST_FILE'] == 'YES'
        config.build_settings[variable] = value
      end
    end
    # If plist doesn't exist, update target with Xcode config
    info_plist_path = get_plist(params,target)
    if info_plist_path.nil?
      puts "No plist found for target #{target.name} updating xcode project variable "
      target.build_configurations.each do |config|
        config.build_settings[variable] = value
      end
      return
    end
    
    plist = Xcodeproj::Plist.read_from_path(info_plist_path)
end

def get_plist(params, target)
  scheme_name = params[:scheme]
  scheme_file = File.join(params[:xcodeproj], 'xcshareddata', 'xcschemes', "#{scheme_name}.xcscheme")
  if File.exist?(scheme_file) && params[:configuration].nil?
    scheme = Xcodeproj::XCScheme.new(scheme_file)
    puts "Archiving configuration: #{scheme.archive_action.build_configuration}"
    params[:configuration] = scheme.archive_action.build_configuration
  end

  if params[:configuration]
    build_config = target.build_configurations.detect { |c| c.name == params[:configuration] }
  else
    puts "Configuration  #{params[:configuration]} not found. Make sure scheme is shared and configuration is present."
    exit 0
  end
  repository_path = env_has_key('AC_REPOSITORY_DIR')
  project_path = env_has_key('AC_PROJECT_PATH')
  project_path = (Pathname.new repository_path).join(Pathname.new(project_path))
  project_directory = File.dirname(project_path)
  info_plist = build_config.build_settings["INFOPLIST_FILE"]
  if info_plist.nil?
    return nil
  end
  info_plist_path = (Pathname.new project_directory).join(Pathname.new(info_plist))
  puts info_plist_path
  return info_plist_path
end

def read_permissions_from_info_plist(params, variable)
  target = find_target(params)
  info_plist_path = get_plist(params, target)
  puts target
  if info_plist_path.nil?
    puts "Can't read plist file. Read from Xcode variable: #{variable}"
    permissions_from_build_settings = get_value_from_build_settings!(target, variable, params[:configuration]) || get_value_from_build_settings!(project, variable, params[:configuration])
    return permissions_from_build_settings
  end

  plist_data = Plist.parse_xml(info_plist_path)

  permissions = plist_data["UIApplicationSceneManifest"]
  if permissions
    puts "Permissions:"
    permissions.each do |key, value|
      puts "#{key}: #{value}"
    end
  else
    puts "UIApplicationSceneManifest permissions not found."
  end
end

def find_target(params)
  project = Xcodeproj::Project.open(params[:xcodeproj])
  target = project.targets.detect do |t|
    t.is_a?(Xcodeproj::Project::Object::PBXNativeTarget) &&
      t.product_type == 'com.apple.product-type.application'
  end
  target
end

def write_values_to_file(values, output_dir ,permission_result)
  output_path = File.join(output_dir, permission_result)
  File.open(output_path, 'w') do |file|
    values.each do |key, value|
      file.puts("#{key}: #{value}")
    end
  end
end


def compare_files(new_permission, old_permission)
  puts "diff compare files fonk"
  
  new_permission_line = new_permission.split("\n")
  old_permission_line = old_permission.split("\n")
  
  differ = Diff::LCS.diff(new_permission_line, old_permission_line)

  puts differ[0]
  
  differ.each do |change|
    case change.action
    when '-'
      puts "Silindi: #{change.element}"
    when '+'
      puts "Eklendi: #{change.element}"
    when ' '
      puts "Aynı: #{change.element}"
    end
  end
end

def read_file_content(file_path)
  File.read(file_path)
end

scheme = env_has_key('AC_SCHEME')
params = {}
params[:configuration] = get_env('AC_IOS_CONFIGURATION_NAME')
params[:xcodeproj] = xcode_project_file
params[:scheme] = scheme
params[:targets] = get_env("AC_TARGETS")

begin
  xcode_permissions = read_permissions_from_info_plist(params, 'INFOPLIST_KEY_')
  permission_result = 'permission_result.txt'
  output_path = get_env_variable('AC_OUTPUT_DIR')
  write_values_to_file(xcode_permissions, output_path, permission_result)

  build_profile_id = get_env_variable('AC_BUILD_PROFILE_ID')
  git_branch = get_env_variable('AC_GIT_BRANCH')

  cached_permission_result = read_file_content("#{output_path}/permission_result.txt")
  previous_permission_result = read_file_content("#{output_path}/#{permission_result}")

  compare_files(cached_permission_result, previous_permission_result)

  exit 0
rescue StandardError => e
  puts "Your project is not compatible. Project is not updated. \nError: #{e} "
  exit 0
end