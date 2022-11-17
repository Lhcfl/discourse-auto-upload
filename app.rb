#!/usr/bin/ruby
# -*- coding: UTF-8 -*-
require "discourse_api"
require "yaml"
require 'find'

client_config = YAML.load(File.open("config.yml"))
if client_config["additional_tags"] == nil
    client_config["additional_tags"] = []
end
client = DiscourseApi::Client.new(client_config["website_url"])
client.api_key = client_config["api_key"]
client.api_username = client_config['api_username']

lib_file = File.open('lib.yml', 'r+')
my_lib = YAML.load(lib_file)
if !my_lib
    my_lib = {}
end

def get_information_from_md_head(content)
    ret = nil;
    tmp = content.strip.split("---")
    if tmp[0] == '' && tmp.length >= 2
        begin
            ret = YAML.load(tmp[1])
        rescue
            ret = nil
        end    
    end
    return ret
end

def get_tiltle_from_content(content)
    ttl = content
    # get Markdown title
    if content.index("\# ")
        ttl = content.split('# ')[1].split("\n")[0]
    end
    # no Markdown title, get first line
    ttl.split("\n").each do |lines|
        if lines != ''
            ttl = lines[0..50]
            break
        end
    end
    # no first line, return nil
    if ttl == ''
        ttl = nil
    end
    return ttl
end


def get_topic_from_file(file_name)
    af = IO.readlines(file_name)
    str = ''
    if af
        af.each {|ch| str = str + ch;}
    else
        return nil
    end
    # Try get Markdown head
    topic_data = get_information_from_md_head(str)
    
    if topic_data
        if str.index("---",2) != nil
             str = str[(str.index("---",2)+3)...]
        end
    end
    # failed; Try get from content
    if topic_data == nil
        topic_data = {"title" => nil}
        topic_data["title"] = get_tiltle_from_content(str)
    end

    # failed; Try get from filename
    if topic_data["title"] == nil
        topic_data["title"] = file_name.split(".")[0]
    end
    
    # failed; Try get from raw filename
    if topic_data["title"] == nil
        topic_data["title"] = file_name
    end
    


    puts "title: #{topic_data['title']}"
    
    # add some into tail
    begin
        if topic_data['date']
            str << "\n\n最初发布于: [date=#{topic_data['date'].to_s} ]"
        end
        if topic_data['author']
            str << "\n\n作者: #{topic_data['author']}"
        end
        if topic_data['toc'] == true
            str << "\n\n" << '<div data-theme-toc="true"> </div>'
        end
    rescue Exception => e  
        puts "Failed: "
        puts e.message  
        puts e.backtrace.inspect 
    end

    # change tag
    if topic_data['tags'] == nil
        topic_data['tags'] = []
    end
    return {
        title: topic_data["title"],
        tags: topic_data['tags'],
        raw_str: str,
        other_information: topic_data,
    }
end



root_dir = Dir.pwd

failed_list = []
details_failed_list = {}
total_success = 0

client_config["workflow"].each do |works|
    Dir.chdir(root_dir)
    to_iter_dir = []
    if works["recursive"]
        works["dir"].each do |paths|
            Find.find(paths).each do |adds|
                if FileTest.directory? adds
                    to_iter_dir << adds
                end
            end
        end
    else
        to_iter_dir = works["dir"]
    end
    
    if works["tags"] == nil
        works["tags"] = []
    end
        
    
    to_iter_dir.each do |dir_name|
        Dir.chdir(root_dir)
        Dir.chdir(dir_name)
        
        need_files = Dir[*(works['mode_str'])]

        need_files.each do |file_name|
            puts "----------"
            topic_ned = get_topic_from_file(file_name)
            if topic_ned == nil
                next
            end
            if topic_ned[:raw_str].length < client_config['require_min_length']
                failed_list << "#{dir_name}/#{file_name}"
                details_failed_list[dir_name + file_name] = {
                    message: "字数过少"
                }
                puts "字数过少，自动跳过"
                next
            end
            if topic_ned[:raw_str].length > client_config['require_max_length']
                failed_list << "#{dir_name}/#{file_name}"
                details_failed_list[dir_name + file_name] = {
                    message: "字数过多"
                }
                puts "字数过多，自动跳过"
                next
            end

            if topic_ned[:tags].class == String
                topic_ned[:tags] = [ topic_ned[:tags] ]
            end

            try_time = 1
            begin
                total_success = total_success + 1
                if (my_lib["#{dir_name}/#{file_name}"])
                    puts '已发布过该主题, 尝试修订'
                    client.edit_post(
                        my_lib["#{dir_name}/#{file_name}"]["id"],
                        topic_ned[:raw_str]
                    )
                else
                    info = client.create_topic(
                        category: works['category_num'],
                        skip_validations: true,
                        auto_track: false,
                        title: topic_ned[:title],
                        raw: topic_ned[:raw_str],
                        tags: client_config["additional_tags"] + works["tags"] + topic_ned[:tags],
                    )
                    
                    my_lib["#{dir_name}/#{file_name}"] = {
                        "id" => info["id"],
                        "topic_id" => info["topic_id"]
                    }
                    
                end
                # change timemap
                if topic_ned[:other_information]
                    if topic_ned[:other_information]["date"]
                        client.edit_topic_timestamp(
                            my_lib["#{dir_name}/#{file_name}"]["topic_id"], 
                            topic_ned[:other_information]["date"].to_i
                        )
                    end
                end
            rescue Exception => e  
                try_time = try_time + 1
                puts "Failed: "
                puts e.message  
                puts e.backtrace.inspect 
                puts "-----------"
                puts topic_ned[:other_information]

                if try_time <= 3
                    puts "Have try #{try_time} times, Wait for 10 sec for try again"
                    sleep(10)
                    retry
                else 
                    failed_list << "#{dir_name}/#{file_name}"
                    details_failed_list[dir_name + file_name] = {
                        message: e.message,
                        inspect: e.backtrace.inspect,
                        details: topic_ned[:other_information],
                        raw_str: topic_ned[:raw_str]
                    }
                end
            end

            puts "-----------"
            puts "Title: #{topic_ned[:title]} 任务已执行完成"
            puts "Wait for 1 sec for next"
            sleep(1)

        end
        Dir.chdir(root_dir)
        lib_fil = File.new('lib.yml', 'w+')
        lib_fil << YAML.dump(my_lib)
    end

end

puts "ALL OK! #{total_success} uploaded, #{failed_list.length} failed, they are:"


Dir.chdir(root_dir)
lib_fil = File.new('lib.yml', 'w+')
lib_fil << YAML.dump(my_lib)
# puts YAML.dump(my_lib)

failed_list.each do |failed_file_name|
    puts "- #{failed_file_name}"
end

if failed_list.length > 0
    log_file = File.new('failed.log', 'w')
    log_file.syswrite(YAML.dump(details_failed_list))

    puts "Look failed.log to see details"
end