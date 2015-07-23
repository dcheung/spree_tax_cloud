module Spree
  class Calculator::TaxCloudCalculator < Calculator::DefaultTax
    def self.description
      Spree.t(:tax_cloud)
    end

    # Default tax calculator still needs to support orders for legacy reasons
    # Orders created before Spree 2.1 had tax adjustments applied to the order, as a whole.
    # Orders created with Spree 2.2 and after, have them applied to the line items individually.
    def compute_order(order)
      raise 'Spree::TaxCloud is designed to calculate taxes at the shipment and line-item levels.'
    end

    # When it comes to computing shipments or line items: same same.
    def compute_shipment_or_line_item(item)
      if rate.included_in_price
        raise 'TaxCloud cannot calculate inclusive sales taxes.'
      else
        round_to_two_places(tax_for_item(item))
        # TODO take discounted_amount into account. This is a problem because TaxCloud API does not take discounts nor does it return percentage rates.
      end
    end

    alias_method :compute_shipment, :compute_shipment_or_line_item
    alias_method :compute_line_item, :compute_shipment_or_line_item

    def compute_shipping_rate(shipping_rate)
      if rate.included_in_price
        raise 'TaxCloud cannot calculate inclusive sales taxes.'
      else
        # Sales tax will be applied to the Shipment itself, rather than to the Shipping Rates.
        # Note that this method is called from ShippingRate.display_price, so if we returned
        # the shipping sales tax here, it would display as part of the display_price of the 
        # ShippingRate, which is not consistent with how US sales tax typically works -- i.e.,
        # it is an additional amount applied to a sale at the end, rather than being part of
        # the displayed cost of a good or service.
        return 0
      end
    end

    private

    def tax_for_item(item)
      order = item.order
      ##AP ADDITION: Modify code to get ship_address from shipment
      if item.instance_of?(Spree::LineItem)
        return 0 unless item.inventory_units.any?
        shipment = item.inventory_units.first.shipment
      else
        shipment = item
      end
      item_address = shipment.address || order.billing_address
      ##END AP ADDITION
      # Only calculate tax when we have an address and it's in our jurisdiction
      return 0 unless item_address.present? && calculable.zone.include?(item_address)

      # Cache will expire if the order, any of its line items, or any of its shipments change.
      # When the cache expires, we will need to make another API call to TaxCloud.
      Rails.cache.fetch(["TaxCloudRatesForItem", item.tax_cloud_cache_key], time_to_idle: 5.minutes) do

        # TODO There may be a way to refactor this,
        # possibly by overriding the TaxCloud::Responses::Lookup model
        # or the CartItems model.
        # Retrieve line_items from lookup
        order.shipments.each do |shipment|
          index = -1 # array is zero-indexed
          # In the case of a cache miss, we recompute the amounts for _all_ the LineItems and Shipments for this Order.
          transaction = Spree::TaxCloud.transaction_from_shipment(shipment)
          lookup_cart_items = transaction.lookup.cart_items
          # Now we will loop back through the items and assign them amounts from the lookup.
          # This inefficient method is due to the fact that item_id isn't preserved in the lookup.
          shipment.line_items.each do |line_item|
            Rails.cache.write(["TaxCloudRatesForItem", line_item.tax_cloud_cache_key], lookup_cart_items[index += 1].tax_amount, time_to_idle: 5.minutes)
          end
          Rails.cache.write(["TaxCloudRatesForItem", shipment.tax_cloud_cache_key], lookup_cart_items[index += 1].tax_amount, time_to_idle: 5.minutes)
        end

        # Lastly, return the particular rate that we were initially looking for
        Rails.cache.read(["TaxCloudRatesForItem", item.tax_cloud_cache_key])
      end
    end
  end
end
