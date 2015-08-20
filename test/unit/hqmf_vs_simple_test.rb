require 'fileutils'
require 'digest'
require_relative '../test_helper'

class HQMFVsSimpleTest < Minitest::Test
  RESULTS_DIR = File.join('tmp','hqmf_simple_diffs')

#  HQMF_ROOT = File.join('test', 'fixtures', 'hqmf', '2_4_0_bundle')
  HQMF_ROOT = File.join('test', 'fixtures', 'hqmf', 'eh_2014')

#  SIMPLE_XML_ROOT = File.join('test','fixtures','simplexml','2_4_0_bundle')
  SIMPLE_XML_ROOT = File.join('test','fixtures','simplexml','eh_2014')

  # Create a blank folder for the errors
  FileUtils.rm_rf(RESULTS_DIR) if File.directory?(RESULTS_DIR)
  FileUtils.mkdir_p RESULTS_DIR

  # Automatically generate one test method per measure file
  measure_files = File.join(HQMF_ROOT, '*.xml')
  
  Dir.glob(measure_files).each do | measure_filename |
    # next unless (measure_filename.ends_with? 'ED3_eMeasure.xml')
    measure_name = File.basename(measure_filename, ".xml")
    define_method("test_#{measure_name}") do
      do_roundtrip_test(measure_filename, measure_name)
    end
  end

  def do_roundtrip_test(measure_filename, measure_name)
    puts ">> #{measure_name}"
    # parse the model from the V1 XML
    hqmf_model = HQMF::Parser::V1Parser.new.parse(File.open(measure_filename).read)
    # rebuild hqmf model so that source data criteria are different objects
    hqmf_model = HQMF::Document.from_json(JSON.parse(hqmf_model.to_json.to_json, {max_nesting: 100}))

    simple_xml = File.join(SIMPLE_XML_ROOT, "#{hqmf_model.cms_id}.xml")
    simple_xml_model = SimpleXml::Parser::V1Parser.new.parse(File.read(simple_xml))

    # ignore the attributes... these are not that important
    hqmf_model.instance_variable_set(:@attributes, [])
    simple_xml_model.instance_variable_set(:@attributes, [])

    # reject the negated source data criteria... these are bad artifacts from HQMF v1.0
    # we also want to pull those from the derived data criteria as well, but not all the negated from there, only the bad from the source data criteria
    hqmf_model.source_data_criteria.reject! {|dc| dc.negation}

    # only compare referenced data criteria since those are the ones that will impact calculation
    referenced_ids = hqmf_model.referenced_data_criteria.map(&:id)
    hqmf_model.all_data_criteria.reject! {|dc| !referenced_ids.include? dc.id }
    referenced_ids = simple_xml_model.referenced_data_criteria.map(&:id)
    simple_xml_model.all_data_criteria.reject! {|dc| !referenced_ids.include? dc.id }

    # fix the descriptions on hqmf data criteria to align with better simpleXML descripions
    # also remove empty units in hqmf and AnyValue entries on TIMEDIFF
    (hqmf_model.all_data_criteria + hqmf_model.source_data_criteria).each do |dc|
      fix_hqmf_clinical_trial(dc)
      fix_hqmf_description(dc)
      fix_subset_operators(dc)
    end

    # HQMF leaf preconditions sometimes have conjunction codes as well as a reference... 
    # we want to clear those conjunction codes before comparison as they are not needed
    hqmf_model.all_population_criteria.each do |pc|
      clear_conjunctions_on_references(pc)
    end

    remap_ids(hqmf_model)
    remap_ids(simple_xml_model)

    simple_xml_model.all_population_criteria.each do |pc|
      # replace HQMF ID for populations... that does not get set properly in the HQMF
      pc.instance_variable_set(:@hqmf_id, hqmf_model.population_criteria(pc.id).hqmf_id)

      # set title on DENEX to denominator since the title is bad out of HQMF
      pc.instance_variable_set(:@title, 'Denominator') if pc.type == 'DENEX'
    end

    # COMPARE

    hqmf_json = JSON.parse(hqmf_model.to_json.to_json, {max_nesting: 100})
    simple_xml_json = JSON.parse(simple_xml_model.to_json.to_json, {max_nesting: 100})

    diff = hqmf_json.diff_hash(simple_xml_json, true, true)

    unless diff.empty?
      outfile = File.join("#{RESULTS_DIR}","#{measure_name}_diff.json")
      File.open(outfile, 'w') {|f| f.write(JSON.pretty_generate(JSON.parse(diff.to_json))) }
      outfile = File.join("#{RESULTS_DIR}","#{measure_name}_hqmf.json")
      File.open(outfile, 'w') {|f| f.write(JSON.pretty_generate(hqmf_json)) }
      outfile = File.join("#{RESULTS_DIR}","#{measure_name}_simplexml.json")
      File.open(outfile, 'w') {|f| f.write(JSON.pretty_generate(simple_xml_json)) }
      outfile = File.join("#{RESULTS_DIR}","#{measure_name}_crit_diff.json")
      File.open(outfile, 'w') {|f|
        f.puts((hqmf_model.all_data_criteria-hqmf_model.source_data_criteria).collect{|dc| dc.id})
        f.puts
        f.puts((simple_xml_model.all_data_criteria-simple_xml_model.source_data_criteria).collect{|dc| dc.id})
        f.puts
        f.puts((hqmf_model.all_data_criteria).collect{|dc| dc.id})
      }
    end
      
    #puts "#{measure_name} -- #{hqmf_model.derived_data_criteria.count}  --  #{simple_xml_model.derived_data_criteria.count} -- #{(hqmf_model.derived_data_criteria.count.to_f/simple_xml_model.derived_data_criteria.count.to_f).to_f}"
    #puts "#{measure_name} -- #{hqmf_model.source_data_criteria.count}  --  #{simple_xml_model.source_data_criteria.count} -- #{(hqmf_model.source_data_criteria.count.to_f/simple_xml_model.source_data_criteria.count.to_f).to_f}"
    # puts "#{measure_name} -- #{hqmf_model.all_data_criteria.count}  --  #{simple_xml_model.all_data_criteria.count} -- #{(hqmf_model.all_data_criteria.count.to_f/simple_xml_model.all_data_criteria.count.to_f).to_f}"
    assert diff.empty?, 'Differences in model between HQMF and SimpleXml... we need a better comparison mechanism'
    
  end

  def remap_ids(measure_model)

    criteria_list = (measure_model.all_data_criteria + measure_model.source_data_criteria)
    criteria_map = get_criteria_map(criteria_list)


    # Normalize the HQMF model IDS
    criteria_list.each do |dc|
      dc.id = hash_criteria(dc, criteria_map)
      dc.instance_variable_set(:@source_data_criteria, dc.id)
      if dc.type == :derived
        dc.instance_variable_set(:@title, dc.id)
      end
    end

    measure_model.all_population_criteria.each do |pc|
      remap_preconditions(criteria_map, pc.preconditions)
    end

  end

  def remap_preconditions(criteria_map, preconditions)
    return if preconditions.nil?
    preconditions.each do |precondition|
      remap_preconditions(criteria_map, precondition.preconditions)
      unless precondition.reference.nil?
        if data_criteria = criteria_map[precondition.reference.id]
          precondition.reference.id = data_criteria.id
        end
      end
    end
  end

  def hash_criteria(criteria, criteria_map)
    return criteria.id unless criteria_map[criteria.id]

    # generate a SHA256 hash of key fields in the data criteria
    #sha256 = Digest::SHA256.new
    # uncomment to keep string undigested for comparison
    sha256 = ''

    sha256 << "#{criteria.code_list_id}:"
    sha256 << "#{criteria.definition}:"
    sha256 << (criteria.status.nil? ? "<nil>:" : "#{criteria.status}:")
    sha256 << "#{criteria.negation}:"
    sha256 << (criteria.specific_occurrence.nil? ? "<nil>:" : "#{criteria.specific_occurrence}:")
    sha256 << (criteria.negation_code_list_id.nil? ? "<nil>:" : "#{criteria.negation_code_list_id}:")

    # build hashes of each complex child... these will update refereces to other data criteria as the hash is built
    sha256 << (criteria.value.nil? ? "<nil>:" : "#{hash_values(criteria.value)}:")
    sha256 << (criteria.children_criteria.nil? ? "<nil>:" : "#{hash_children(criteria.children_criteria, criteria_map)}:")
    sha256 << (criteria.subset_operators.nil? ? "<nil>:" : "#{hash_subsets(criteria.subset_operators)}:")
    sha256 << (criteria.temporal_references.nil? ? "<nil>:" : "#{hash_temporals(criteria.temporal_references, criteria_map)}:")
    sha256 << (criteria.field_values.nil? ? "<nil>:" : "#{hash_fields(criteria.field_values)}:")

    #sha256.hexdigest
    sha256
  end

  def hash_subsets(list)
    Digest::SHA256.hexdigest list.map {|x| x.to_json.to_json}.join(',')
  end

  def hash_temporals(list, criteria_map)
    list.each do |t|
      t.reference.id = hash_criteria(criteria_map[t.reference.id], criteria_map) if criteria_map[t.reference.id]
    end

    Digest::SHA256.hexdigest list.map {|x| x.to_json.to_json}.join(',')
  end

  def hash_children(list, criteria_map)
    list.map! {|id| hash_criteria(criteria_map[id], criteria_map)} if list.select {|id| criteria_map[id]}.length == list.length
    list.join(',')
  end

  def hash_fields(hash)
    hash.values.each {|fv| fv.instance_variable_set(:@title,'')}
    Digest::SHA256.hexdigest hash.to_json
  end

  def hash_values(value)
    value.instance_variable_set(:@title, '') if value.type == 'CD'
    Digest::SHA256.hexdigest value.to_json.to_json
  end

  # from hqmf the unit on counts can sometimes be " "... we want to clear these
  def fix_subset_operators(dc)
    if (dc.subset_operators)
      dc.subset_operators.each do |subset|
        subset.value.high.instance_variable_set(:@unit, nil) if subset.value.respond_to?(:high) && subset.value.try(:high).try(:unit).try(:strip).try(:empty?)
        subset.value.low.instance_variable_set(:@unit, nil) if subset.value.respond_to?(:low) && subset.value.try(:low).try(:unit).try(:strip).try(:empty?)
        subset.value = nil if subset.type == 'TIMEDIFF' && subset.value.is_a?(HQMF::AnyValue)
      end
    end
  end

  def clear_conjunctions_on_references(precondition)
    if (precondition.preconditions && !precondition.preconditions.empty?)
      precondition.preconditions.each do |child|
        clear_conjunctions_on_references(child)
      end
    else
      if (precondition.respond_to?(:reference) && precondition.reference && precondition.conjunction_code)
        precondition.instance_variable_set(:@conjunction_code,nil)
      end
    end
  end

  def fix_hqmf_clinical_trial(dc)
    if dc.definition == 'patient_characteristic_clinical_trial_participant'
      dc.definition = 'patient_characteristic'
      dc.status = 'clinical_trial_participant'
    end
  end

  def fix_hqmf_description(dc)

    orig = dc.description.dup
    dc.description.sub!('Diagnostic Study Result','Diagnostic Study, Result') if dc.description.starts_with? "Diagnostic Study Result"
    dc.description.sub!('Laboratory Test:','Laboratory Test, Result:') if dc.description.starts_with? "Laboratory Test:"
    dc.description.sub!('Physical Exam:','Physical Exam, Finding:') if dc.description.starts_with? "Physical Exam:"
    dc.description.sub!('Communication From Provider To Provider:','Communication: From Provider to Provider:') if dc.description.starts_with? "Communication From Provider To Provider:"
    dc.description.sub!('Functional Status Result:','Functional Status, Result:') if dc.description.starts_with? "Functional Status Result:"
    dc.description.sub!('Procedure Result:','Procedure, Result:') if dc.description.starts_with? "Procedure Result:"
    dc.description.sub!('Medication Allergy:','Medication, Allergy:') if dc.description.starts_with? "Medication Allergy:"
    dc.description.sub!('Medication Intolerance:','Medication, Intolerance:') if dc.description.starts_with? "Medication Intolerance:"
    dc.description.sub!('Procedure Intolerance:','Procedure, Intolerance:') if dc.description.starts_with? "Procedure Intolerance:"

    dc.instance_variable_set(:@specific_occurrence_const, SimpleXml::DataCriteria.format_so_const(dc.description)) if orig != dc.description
  end

  def get_criteria_map(criteria_list)
    criteria_map = {}
    criteria_list.each do |dc|
      criteria_map[dc.id] = dc
    end
    criteria_map
  end

end
