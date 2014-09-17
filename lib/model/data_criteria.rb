module SimpleXml
  # Represents a data criteria specification
  class DataCriteria

    attr_accessor :id, :field_values, :value, :negation, :negation_code_list_id,
        :derivation_operator, :children_criteria, :subset_operators, :comments,
        :temporal_references, :specific_occurrence, :specific_occurrence_const
    attr_reader :hqmf_id, :title, :display_name, :description, :code_list_id, 
        :definition, :status, :effective_time, :inline_code_list, :source_data_criteria
  
    include SimpleXml::Utilities
    
    # Create a new instance based on the supplied HQMF entry
    # @param [Nokogiri::XML::Element] entry the parsed HQMF entry
    def initialize(entry, id=nil)
      @entry = entry

      if (@entry)
        create_criteria(@entry, id)
      else
        create_grouping_criteria(id)
      end

      @source_data_criteria = @id
      @negation = false
      
      # the following remain nil:
      # @display_name, @children_criteria, @derivation_operator, @value, @field_values,
      # @effective_time , @inline_code_list, @negation_code_list_id, @temporal_references, @subset_operators
    end

    def create_criteria(entry, id)
      @entry = entry

      type = attr_val('@datatype')
      name = attr_val('@name')
      instance = attr_val('@instance')

      @description = "#{type}: #{name}"
      @title = name
      @code_list_id = attr_val('@oid')

      @hqmf_id = attr_val('@uuid')

      parts = type.split(',')
      def_and_status = parse_definition_and_status(type)
      @definition = def_and_status[:definition]
      @status = def_and_status[:status]

      specifics_counter = nil
      if instance
        fix_description_for_hqmf_match()
        specifics_counter = HQMF::Counter.instance.next
        @specific_occurrence = instance.split[1]
        @specific_occurrence_const = DataCriteria.format_so_const(@description)
        @id = id || format_id("#{instance} #{@title}#{specifics_counter}")
      else
        @id = id || format_id("#{@description}")
      end

      handle_transfer() if (['transfer_from', 'transfer_to'].include? definition)


    end

    def create_grouping_criteria(id)
      @id = id
      @definition = 'derived'
      @description = ""
      @title = @id
    end

    def self.get_criteria(element, precondition_id, doc, subset=nil, operator=nil, update_id=false)
      
      if element.name == Precondition::TEMPORAL_OP
        # we have a chain of temporal references
        criteria = convert_precondition_to_criteria(Precondition.new(element, doc), doc, operator)
      elsif element.name == Precondition::LOGICAL_OP || element.name == Precondition::SET_OP
        # we have a logical group on the right
        criteria = convert_precondition_to_criteria(Precondition.new(element, doc), doc, operator)
      elsif element.name == Precondition::FUNCTIONAL_OP
        criteria = doc.data_criteria(Precondition.new(element, doc).reference.id)
      else
        criteria = doc.criteria_map[element.at_xpath('@id').value]
        if !criteria && element.name == Precondition::SUB_TREE
          criteria = doc.sub_tree_map[Utilities.attr_val(element, '@id')].convert_to_data_criteria
          doc.register_source_data_criteria(criteria)
        end
        criteria = criteria.dup
        return criteria if criteria.id == HQMF::Document::MEASURE_PERIOD_ID

        # if we have attributes then we want to update the ID sice we have changed the DC
        attributes = element.xpath('attribute')
        update_id = update_id || !attributes.empty?

        criteria.id = "#{criteria.id}_precondition_#{precondition_id}" if update_id
        doc.derived_data_criteria << criteria unless doc.derived_data_criteria.map(&:id).include? criteria.id

        # handle attributes
        if (attributes)
          attributes.each do |attribute|
            
            orig_key = attribute.at_xpath('@name').value
            key = DataCriteria.translate_field(orig_key)
            value = Attribute.translate_attribute(attribute, doc)

            if key == 'RESULT'
              criteria.value = value
            elsif key == 'NEGATION_RATIONALE'
              criteria.negation = true
              criteria.negation_code_list_id = value.code_list_id
            else
              criteria.field_values ||= {}
              criteria.field_values[key] = value
            end

          end
        end
      end

      if subset
        criteria.subset_operators ||= []
        criteria.subset_operators << subset
      end

      criteria
    end

    def self.convert_precondition_to_criteria(precondition, doc, operator)
      if (precondition.reference)
        # precondition is a single element
        criteria = doc.data_criteria(precondition.reference.id)
      else
        # precondition is a group
        criteria = convert_to_grouping(precondition, doc, operator)
        doc.derived_data_criteria << criteria
      end
      criteria
    end

    def self.convert_to_grouping(precondition, doc, operator)
      grouping = DataCriteria.new nil, "GROUP_#{operator}_CHILDREN_#{HQMF::Counter.instance.next}"
      grouping.children_criteria = precondition.preconditions.map {|p| convert_precondition_to_criteria(p, doc, operator).id}
      grouping.derivation_operator = case precondition.conjunction_code
                                     when HQMF::Precondition::ALL_TRUE then HQMF::DataCriteria::XPRODUCT
                                     when SimpleXml::Precondition::INTERSECTION then HQMF::DataCriteria::INTERSECT
                                     else HQMF::DataCriteria::UNION
                                     end
      grouping
    end
    
    def dup
      if @entry
        DataCriteria.new(@entry, @id)
      else
        Marshal.load(Marshal.dump(self))
      end
    end

    def add_temporal(temporal)
      @temporal_references ||= []
      @temporal_references << temporal
    end

    def push_down_temporal(temporal, doc)
      # push down through a grouping
      if @children_criteria
        @children_criteria.each {|child_id| doc.data_criteria(child_id).push_down_temporal(temporal, doc)} 
      else
        # if this is not a grouping, just add the temporal reference
        add_temporal(temporal)
      end
    end

    def handle_specific_occurrence(instance)
      fix_description_for_hqmf_match()
      specifics_counter = HQMF::Counter.instance.next
      @specific_occurrence = instance
      @specific_occurrence_const = DataCriteria.format_so_const(@description)
      @id = id || format_id("#{instance} #{@title}#{specifics_counter}")
    end
    
    def self.translate_field(name)
      name = name.tr(' ','_').upcase
      name = 'ORDINAL' if name == 'ORDINALITY'
      raise "Unknown field name: #{name}" unless HQMF::DataCriteria::FIELDS[name] || name == 'RESULT' || name == 'NEGATION_RATIONALE'
      name
    end

    def to_model

      trs = temporal_references.collect {|t| t.to_model} if temporal_references
      if field_values
        fv = {}
        field_values.each {|k, v| fv[k] = v.to_model}
      end
      val = value.to_model if value
      subs = subset_operators.collect {|o| o.to_model} if subset_operators
      @variable ||= false

      HQMF::DataCriteria.new(@id, @title, @display_name, @description, @code_list_id, @children_criteria, 
        @derivation_operator, @definition, @status, val, fv, @effective_time, @inline_code_list, 
        @negation, @negation_code_list_id, trs, subs, @specific_occurrence, 
        @specific_occurrence_const, @source_data_criteria, comments, @variable)
    end

    def self.format_so_const(description)
      description.gsub(/\W/,' ').upcase.split.join('_')
    end

    private

    def format_id(value)
      value.gsub(/\W/,' ').split.collect {|word| word.strip.capitalize }.join
    end

    def parse_definition_and_status(type)

      type = type.gsub('Patient Characteristic', 'Patient Characteristic,') if type.starts_with? 'Patient Characteristic'
      case type
      when 'Patient Characteristic, Sex'
        type = 'Patient Characteristic, Gender'
      end

      settings = HQMF::DataCriteria.get_settings_map.values.select {|x| x['title'] == type.downcase}
      raise "multiple settings found for #{type}" if settings.length > 1
      settings = settings.first

      if (settings.nil?)
        parts = type.split(',')
        definition = parts[0].tr(':','').downcase.strip.tr(' ','_')
        status = parts[1].downcase.strip.tr(' ','_') if parts.length > 1
        settings = {'definition' => definition, 'status' => status}
      end

      definition = settings['definition']
      status = settings['status']

      # fix oddity with medication discharge having a bad definition
      if definition == 'medication_discharge'
        definition = 'medication'
        status = 'discharge'
      end 
      status = nil if status && status.empty?

      {definition: definition, status: status}
    end

    def handle_transfer
      @field_values ||= {}
      value = Coded.new(@code_list_id,@title)
      @field_values[definition.upcase] = value
      @code_list_id = nil
    end

    # TODO: Move this fix into hqmf parser instead
    def fix_description_for_hqmf_match
      @description = "#{@definition.titleize}, #{@status.titleize}: #{@title}" if @status == 'ordered'
    end
 
  end
  
end
