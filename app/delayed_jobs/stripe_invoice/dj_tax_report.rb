module StripeInvoice
  class DJTaxReport
    def initialize(year = 1.year.ago.year)
      @year = year
    end
    
    
    def perform
      puts "[#{self.class.name}##{__method__.to_s}] computing tax report for #{@year}"
      
      sicharges = StripeInvoice::Charge.where(
            "date >= ? and date <= ?", 
            date_to_epoch("#{@year}-01-01"), 
            date_to_epoch("#{@year}-12-31"))
            
      puts "[#{self.class.name}##{__method__.to_s}] number of charges in year: #{sicharges.size}"
      arr_data = []
      sicharges.each do |charge|
        owner = charge.owner
        
        next unless owner # skip if we don't have an owner
        
        country = get_country charge
        
        data = {
          charge: charge,
          country: country,
          tax_number: charge.tax_number,
          billing_address: charge.billing_address,
          bt: charge.balance_transaction_object,
          owner: owner,
        }
        puts "[#{self.class.name}##{__method__.to_s}] aggregating data #{charge.stripe_id}"
        if charge.indifferent_json[:refunds].count > 0
          arr_refunds = []
          charge.indifferent_json[:refunds].each do |refund|
            refd = {
              refund: refund,
              bt: Stripe::BalanceTransaction.retrieve(refund[:balance_transaction])
            }
            arr_refunds << refd
          end
          
          data[:refunds] = arr_refunds
          #puts "[DJTaxReport] charge had refunds: #{arr_refunds}"
        end # has refunds
        
        arr_data << data
      end
      
      puts "[#{self.class.name}##{__method__.to_s}] data collected; rendering view"
      #res = InvoicesController.new.tax_report arr_data
      res = Renderer.render template: "stripe_invoice/invoices/tax_report", 
            locals: {sicharges: arr_data, 
              year: @year, 
              totals: totals(arr_data), 
              volume_per_tax_number: volume_per_tax_number(arr_data)}, 
            formats: [:pdf]
      
      InvoiceMailer.tax_report(res).deliver! #unless ::Rails.env.development?
    end
    
    private 
    def date_to_epoch(date)
      Date.strptime(date,"%Y-%m-%d").to_datetime.utc.to_i
    end
    
    def totals(sicharges)
      result = {
        transaction_volume: total_transaction_volume(sicharges),
        transaction_volume_by_country: transaction_volume_by_country(sicharges), 
        fees: total_fee_volume(sicharges),
      }
    end
    
    def volume_per_tax_number(sicharges)
      puts "[#{self.class.name}##{__method__.to_s}] calculating volume per tax id"
      charges = sicharges.group_by do |charge| 
        charge[:tax_number]
      end
      result = []
      charges.each_key do |key|
        next if key.blank?

        result <<  {
          amount: (charges[key].sum {|charge| charge[:charge].balance_transaction_total_less_refunds}),
          currency: charges[key].first[:bt][:currency],
          tax_number: key,
          country: (charges[key].first[:charge].owner.country ? charges[key].first[:charge].owner.country : 
             "CC: #{charges[key].first[:charge].source_country}")
          }
      end
      
      result
    end
    
    include ActionView::Helpers::NumberHelper
    def total_transaction_volume(sicharges)
      number_to_currency(sicharges.inject(0) {|sum, hash_ch| sum + hash_ch[:bt][:amount]} / 100.0, 
        unit: "#{sicharges.first[:bt][:currency].upcase} ")
    end
    
    def total_fee_volume(sicharges)
      number_to_currency(sicharges.inject(0) {|sum, hash_ch| sum + hash_ch[:bt][:fee]} / 100.0, 
        unit: "#{sicharges.first[:bt][:currency].upcase} ")
    end
    
    def transaction_volume_by_country(sicharges)
      result = {}
      
      sicharges.each do |hash_ch| 
        # get value or 0 if not present
        value = result.fetch(hash_ch[:country]) { 0 }
        
        if hash_ch[:refunds]
          hash_ch[:refunds].each do |refund|
            value -= refund[:bt][:amount]
          end
        end # deduct refunds
        result[hash_ch[:country]] = value + hash_ch[:bt][:amount]
      end
      
      result.each do |key, value|
        result[key] = value / 100.0
      end
      
      result.with_indifferent_access
    end
    
    def get_country(charge)
      Country[charge.country] ? charge.country : 
        ((country = Country.find_country_by_name(charge.country)) ? country.alpha2 : 'Unkown Country')
    end
    
    def total_less_refunds(hash_sic)
      total = hash_sic[:charge].total 
      total -= hash_sic[:refunds].sum {|refund| refund[:refund][:amount]} unless hash_sic[:refunds].blank?
    end
  end
end
