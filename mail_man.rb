require 'rubygems'
require 'yaml'
require 'timeout'
require "#{File.dirname(__FILE__)}/pop_ssl"
require 'net/smtp'
require 'tmail'

class MailMan

  TEMPFILE = "/tmp/MailMan"
  TIMEOUT = 45
  STUNNEL_PORT = 20000

  def check
    if File.exists?(TEMPFILE)
      log "Already running. Delete #{TEMPFILE} if this is a mistake."
      return
    end

    accounts = load_accounts

    begin
      File.open(TEMPFILE, 'w') {|f| f.write(self)}

      accounts.each do |acc|
        begin
          log "#{acc['host']}: #{acc['username']}"

          if !decide_connect(acc['host'], acc['username'], acc['min_interval'])
            log "Reconnect-interval too short (soft)."
            next
          end

          Timeout::timeout(TIMEOUT){
            if acc['ssl'] == 'ssl/tls'
              start_pop3(acc['host'], acc['port'], true, acc['username'], acc['password'], acc['redirect_to'])
            elsif acc['ssl'] == 'starttls'
              log "starttls not implemented, yet."
              next
            end
          }
        rescue Timeout::Error
          log "Server did not respond within #{TIMEOUT} seconds."
          next
        ensure
          log "=========="
        end
      end
    ensure
      File.delete(TEMPFILE)
    end
  end

  def load_accounts
    accounts_raw = YAML::load(File.open("#{File.dirname(__FILE__)}/accounts.yaml"))

    accounts = []
    accounts_raw.each do |acc|
      accounts << acc[1]
    end

    return accounts
  end

  def start_pop3(hostname, port, ssl, username, password, redirect_to)
    begin
      if ssl
        Net::POP3.enable_ssl(OpenSSL::SSL::VERIFY_NONE)
      else
        Net::POP3.disable_ssl
      end

      Net::POP3.start(hostname, port, username, password) do |pop|
        if pop.mails.empty?
          log 'No mail.'
        else
          pop.each_mail do |mail|
            begin
            email = TMail::Mail.parse(mail.pop)
            log email.subject
            Net::SMTP.start('localhost') do |smtp|
              begin
                smtp.sendmail(email.to_s, email.from, redirect_to)
              rescue Net::SMTPServerBusy => e
                if e.to_s =~ /^.* Sender address rejected: .*$/
                  log("Deleting mail because blocked by local mail server.")
                  log(" => #{e.to_s}")
                end
              rescue Exception => e
                log "Error while trying to send email."
                log " => #{e.inspect}"
              end
            end
            mail.delete
            rescue Exception => e
              log "Error while trying to parse email."
              log " => #{e.inspect}"
            end
          end
        end
      end
    rescue Net::POPAuthenticationError => e
      # Fix for web.de minimum reconnect-interval
      if e.to_s =~ /^.* Zeitabstand .*$/
        log "Reconnect-interval too short (hard)."
      end
    rescue Exception => e
      log "Error while trying to connect to mail server."
      log " => #{e.inspect}"
    end
  end

  def log(message)
    puts "[#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}] #{message}"
  end

  def decide_connect(hostname, username, min_interval)
    filename = "/tmp/MailMan.#{hostname}_#{username}"

    if !File.exists?(filename)
      File.open(filename, 'w') {|f| f.write(Time.now.to_i)}
      return true
    end

    time_since_run = 0
    File.open(filename, "r") do |infile|
      last_run = infile.gets.to_i
      time_since_run = Time.now.to_i - last_run
    end

    if time_since_run > (60 * min_interval)
      File.open(filename, 'w') {|f| f.write(Time.now.to_i)}
      return true
    else
      return false
    end
  end

end

MailMan.new.check
