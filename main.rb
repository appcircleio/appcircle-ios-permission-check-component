require 'open3'
require 'pathname'
require 'xcodeproj'
require 'json'
require 'net/http'
require 'plist'
require 'English'
require 'fileutils'
require 'diff/lcs'
require 'os'
require 'digest'
require 'set'

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

build_profile_id = get_env_variable('AC_BUILD_PROFILE_ID')
git_branch = get_env_variable('AC_GIT_BRANCH')
output_path = get_env_variable('AC_OUTPUT_DIR')

#ac_cache_included_paths = get_env_variable('AC_CACHE_INCLUDED_PATHS') || abort_with0('Included paths must be defined.')
ac_cache_included_paths = "#{output_path}/permission_result.txt"
ac_cache_excluded_paths = get_env_variable('AC_CACHE_EXCLUDED_PATHS') || ''
ac_repository_path = get_env_variable('AC_REPOSITORY_DIR')
# ac_cache_label = get_env_variable('AC_CACHE_LABEL') || abort_with0('Cache label path must be defined.')
ac_referance_branch = get_env_variable('AC_REFERANCE_BRANCH')
ac_cache_label = "#{build_profile_id}/#{ac_referance_branch}/cache/permission"
breake_workflow = get_env_variable('AC_BREAKE_WORKFLOW')

ac_token_id = get_env_variable('AC_TOKEN_ID') || abort_with0('AC_TOKEN_ID env variable must be set when build started.')
ac_callback_url = get_env_variable('AC_CALLBACK_URL') || abort_with0('AC_CALLBACK_URL env variable must be set when build started.')

signed_url_api = "#{ac_callback_url}?action=getCacheUrls"

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

# write function to file all permissions [Key:Value]
def write_values_to_file(values, output_dir ,permission_result)
  output_path = File.join(output_dir, permission_result)
  File.open(output_path, 'w') do |file|
    values.each do |key, value|
      file.puts("#{key}: #{value}")
    end
  end
end

# diff func
def compare_files(new_permission, old_permission)
  puts "New Permissions: \n #{new_permission}"
  puts "Reference Branch Permissions: \n #{old_permission}"
  
  differ = Diff::LCS.diff(new_permission, old_permission)

  differ.each do |diff|
    if diff.action == '-'
      puts "New permission line different in this line: #{diff.element}"
      if breake_workflow
        exit 1
      else
        exit 0
      end
    elsif
      puts "Referance branch permission line different in this line: #{diff.element}"
      if breake_workflow == 'false'
        exit 1
      else
        exit 0
      end  
    end  
  end
end

def read_file_content(file_path)
  File.read(file_path)
end

# Run cache and permission dif
scheme = env_has_key('AC_SCHEME')
params = {}
params[:configuration] = get_env('AC_IOS_CONFIGURATION_NAME')
params[:xcodeproj] = xcode_project_file
params[:scheme] = scheme
params[:targets] = get_env("AC_TARGETS")

begin
  xcode_permissions = read_permissions_from_info_plist(params, 'INFOPLIST_KEY_')
  permission_result = 'permission_result.txt'
  write_values_to_file(xcode_permissions, output_path, permission_result)
  
  if git_branch == ac_referance_branch
    # Cache permission_result.txt according to referance branch
  def run_command(command)
    unless system(command)
      puts "@@[error] Unexpected exit with code #{$CHILD_STATUS.exitstatus}. Check logs for details."
      exit 0
    end
  end

def run_command_with_log(command)
  puts "@@[command] #{command}"
  s = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  run_command(command)
  e = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  puts "took #{(e - s).round(3)}s"
end

def abort_with0(message)
  puts "@@[error] #{message}"
  exit 0
end

def ac_output_dir
  out_dir = get_env_variable('AC_OUTPUT_DIR')
  out_dir && Dir.exist?(out_dir) ? out_dir : nil
end


# check dependencies
run_command('zip -v |head -2')
run_command('curl --version |head -1')

@cache = "ac_cache/#{ac_cache_label}"
zipped = "ac_cache/#{ac_cache_label.gsub('/', '_')}.zip"

puts '--- Inputs:'
puts ac_cache_label
puts ac_cache_included_paths
puts ac_cache_excluded_paths
puts ac_repository_path
puts '-----------'

env_dirs = Hash.new('')
ENV.each_pair do |k, v|
  env_dirs[v] = k if k.start_with?('AC_') && File.directory?(v)
end

def expand_exclude(pattern)
  if pattern.end_with?('/\*')
    exclude = "#{pattern.delete_suffix!('/\*')}/*"
    exclude = "\"#{exclude}\""
    exclude += " \"#{pattern.gsub('**/', '')}/*\"" if pattern.include? '**/'
  else
    exclude = "\"#{pattern}\""
  end
  exclude
end

def add_includes(included_paths, zip)
  included_paths.each do |f|
    next if ['.', '..'].include?(f)
    next if f.end_with?('.') || f.end_with?('..')

    zip += " #{f}"
  end
  zip
end

def add_excludes(excluded_paths, zip)
  return zip if excluded_paths.empty?

  zip += ' -x'
  excluded_paths.each do |excluded|
    zip += " #{expand_exclude(excluded)}"
  end
  zip
end

def add_log_file(folder, file, zip)
  if ac_output_dir
    system("mkdir -p #{folder}")
    zip += " > #{folder}/#{file}"
  end
  zip
end

def run_zip(zip_file, zip)
  run_command_with_log(zip)
  run_command("ls -lh #{zip_file}")
end

def cache_path(base_path, included_path, excluded_paths, env_dirs)
  puts "Include: #{included_path} in #{base_path}"

  unless Dir.exist?(base_path)
    puts "Warning: #{base_path} doesn't exist yet. Check folder is correct and available."
    return nil
  end

  cwd = Dir.pwd
  Dir.chdir(base_path)
  paths = Dir.glob(included_path.to_s, File::FNM_DOTMATCH)

  if paths.empty?
    Dir.chdir(cwd)
    return nil
  end

  base_path = "/#{env_dirs[base_path]}" if env_dirs.key?(base_path)
  zip_file = "#{cwd}/#{@cache}#{base_path}/#{included_path.gsub('/', '_')}.zip"
  system("mkdir -p #{cwd}/#{@cache}#{base_path}")
  zip = "zip -r -FS #{zip_file}"
  zip = add_includes(paths, zip)
  zip = add_excludes(excluded_paths, zip)
  zip = add_log_file("#{ac_output_dir}/#{@cache}#{base_path}", "#{included_path.gsub('/', '_')}.zip.log", zip)
  run_zip(zip_file, zip)

  Dir.chdir(cwd)
  zip_file
end

def search_env_dirs(path, env_dirs)
  return path if env_dirs.key?(path)

  index_of_slash = path.rindex('/')
  return search_env_dirs(path[0..index_of_slash - 1], env_dirs) if index_of_slash.positive?

  nil
end

def find_base_path(path, env_dirs)
  base_path = ''
  parts = path.split('/')
  order = 1
  parts.each do |w|
    break if order == parts.length
    break if w.include?('*')

    base_path += "/#{w}" unless w.empty?
    order += 1
  end
  env_path = search_env_dirs(base_path, env_dirs)
  env_path || base_path
end

def get_excluded_paths(paths, env_dirs)
  home = '~/'

  excludes = Hash.new('')
  excludes[home] = []
  excludes[''] = [] # repository

  paths.split(':').each do |path|
    next if path.empty?

    if path.start_with?(home)
      path = path[(home.length)..-1]
      excludes[home].push(path)
    elsif path.start_with?('/')
      base_path = find_base_path(path, env_dirs)
      next unless base_path

      excludes[base_path] = [] unless excludes.key?(base_path)
      excludes[base_path].push(path[(base_path.length + 1)..-1])
    else
      excludes[''].push(path)
    end
  end
  excludes
end

excluded_paths = get_excluded_paths(ac_cache_excluded_paths, env_dirs)
puts excluded_paths

uptodate_zips = Set.new([])

ac_cache_included_paths.split(':').each do |included_path|
  next if included_path.empty?

  zip_file = nil
  if included_path.start_with?('~/')
    included_path = included_path[('~/'.length)..-1]
    zip_file = cache_path(ENV['HOME'], included_path, excluded_paths['~/'], env_dirs)
  elsif included_path.start_with?('/')
    base_path = find_base_path(included_path, env_dirs)
    next unless base_path

    zip_file = cache_path(base_path, included_path[(base_path.length + 1)..-1], excluded_paths[base_path], env_dirs)
  elsif ac_repository_path
    zip_file = cache_path(ac_repository_path, included_path, excluded_paths[''], env_dirs)
  else
    puts "Warning: #{included_path} is skipped. It can be used only after Git Clone workflow step."
  end

  uptodate_zips.add(zip_file.sub("#{Dir.pwd}/", '')) if zip_file
end

# remove dead zips (includes) from pulled zips if not in uptodate set
Dir.glob("#{@cache}/**/*.zip", File::FNM_DOTMATCH).each do |zip_file|
  unless uptodate_zips.include?(zip_file)
    system("rm -f #{zip_file}")
    puts "Info: #{zip_file} is not in uptodate includes. Removed."
  end
end
system("find #{@cache} -empty -type d -delete")

run_command("[ -s #{zipped} ] || rm -f #{zipped}")
run_command_with_log("zip -r -0 -FS #{zipped} #{@cache}")
run_command("ls -lh #{zipped}")

if File.exist?("#{zipped}.md5")
  pulled_md5sum = File.open("#{zipped}.md5", 'r', &:readline).strip
  pushed_md5sum = Digest::MD5.file(zipped).hexdigest
  puts "#{pulled_md5sum} =? #{pushed_md5sum}"
  if pulled_md5sum == pushed_md5sum
    puts 'Cache is the same as pulled one. No need to upload.'
    exit 0
  end
end


    unless ac_token_id.empty?
      puts ''
    
      ws_signed_url = "#{signed_url_api}&cacheKey=#{ac_cache_label.gsub('/', '_')}&tokenId=#{ac_token_id}"
      puts ws_signed_url
    
      uri = URI(ws_signed_url)
      response = Net::HTTP.get(uri)
      unless response.empty?
        puts 'Uploading cache...'
    
        signed = JSON.parse(response)
        ENV['AC_CACHE_PUT_URL'] = signed['putUrl']
        puts ENV['AC_CACHE_PUT_URL']
        
        if get_env_variable('AC_CACHE_PROVIDER').eql?('FILESYSTEM')
          curl = 'curl -0 --location --request PUT'
          run_command_with_log("#{curl} '#{ENV['AC_CACHE_PUT_URL']}' --form 'file=@\"#{zipped}\"'")
        else
          curl = 'curl -0 -X PUT -H "Content-Type: application/zip"'
          run_command_with_log("#{curl} --upload-file #{zipped} $AC_CACHE_PUT_URL")
        end
      end
    end
    #Cache Pull
  else
    def get_env_variable(key)
      return nil if ENV[key].nil? || ENV[key].strip.empty?
  
      ENV[key].strip
    end
  
    def run_command(command)
      unless system(command)
      puts "@@[error] Unexpected exit with code #{$CHILD_STATUS.exitstatus}. Check logs for details."
      exit 0
      end
    end
  
    def run_command_with_log(command)
      puts "@@[command] #{command}"
      s = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      run_command(command)
      e = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      puts "took #{(e - s).round(3)}s"
    end
  
    def abort_with0(message)
      puts "@@[error] #{message}"
      exit 0
    end
  
    ac_repository_path = get_env_variable('AC_REPOSITORY_DIR')
    ac_cache_label = "#{build_profile_id}/#{ac_referance_branch}/cache"
  
    ac_token_id = get_env_variable('AC_TOKEN_ID') || abort_with0('AC_TOKEN_ID env variable must be set when build started.')
    ac_callback_url = get_env_variable('AC_CALLBACK_URL') ||
                      abort_with0('AC_CALLBACK_URL env variable must be set when build started.')
  
    signed_url_api = "#{ac_callback_url}?action=getCacheUrls"
  
    # check dependencies
    run_command('unzip -v |head -1')
    run_command('curl --version |head -1')
  
    cache = "ac_cache/#{ac_cache_label}"
    zipped = "ac_cache/#{ac_cache_label.gsub('/', '_')}.zip"
  
    puts '--- Inputs:'
    puts ac_cache_label
    puts ac_repository_path
    puts '-----------'
  
    env_dirs = Hash.new('')
    ENV.each_pair do |k, v|
      next unless k.start_with?('AC_')
      next if v.include?('//') || v.include?(':')
  
      env_dirs[k] = v if File.directory?(v) || %r{^(.+)/([^/]+)$} =~ v
    end
  
    system("rm -rf #{cache}")
    system("mkdir -p #{cache}")
  
    unless ac_token_id.empty?
      puts ''
  
      ws_signed_url = "#{signed_url_api}&cacheKey=#{ac_cache_label.gsub('/', '_')}&tokenId=#{ac_token_id}"
      puts ws_signed_url
  
      uri = URI(ws_signed_url)
      response = Net::HTTP.get(uri)
      unless response.empty?
        puts 'Downloading cache...'
  
        signed = JSON.parse(response)
        ENV['AC_CACHE_GET_URL'] = signed['getUrl']
        puts ENV['AC_CACHE_GET_URL']
        if get_env_variable('AC_CACHE_PROVIDER').eql?('FILESYSTEM')
          run_command_with_log("curl -X GET --fail -o #{zipped} '#{ENV['AC_CACHE_GET_URL']}'")
        else
          run_command_with_log("curl -X GET -H \"Content-Type: application/zip\" --fail -o #{zipped} $AC_CACHE_GET_URL")
        end
      end
    end
  
    exit 0 unless File.size?(zipped)
  
    md5sum = Digest::MD5.file(zipped).hexdigest
    puts "MD5: #{md5sum}"
    File.open("#{zipped}.md5", 'a') do |f|
      f.puts md5sum.to_s
    end
    run_command_with_log("unzip -qq -o #{zipped}")
  
    Dir.glob("#{cache}/**/*.zip", File::FNM_DOTMATCH).each do |zip_file|
      puts zip_file
  
      last_slash = zip_file.rindex('/')
      base_path = zip_file[cache.length..last_slash - 1]
      base_path = env_dirs[base_path[1..-1]] if env_dirs.key?(base_path[1..-1])
  
      puts base_path
      system("mkdir -p #{base_path}")
      run_command_with_log("unzip -qq -u -o #{zip_file} -d #{base_path}/")
    end

  end

  cached_permission_result = read_file_content("#{ac_cache_label}/permission_result.txt")
  previous_permission_result = read_file_content("#{output_path}/#{permission_result}")

  compare_files(cached_permission_result, previous_permission_result)

  exit 0
rescue StandardError => e
  puts "Your project is not compatible. Project is not updated. \nError: #{e} "
  exit 1
end