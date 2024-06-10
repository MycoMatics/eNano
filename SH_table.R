library(dplyr)
library(stringr)
##### SH-function ####
SH_table <- function(otu_df){
  barcode_cols <- names(otu_df)[grepl("^barcode", names(otu_df))]
  otucol <- names(otu_df)[grepl("OTU", names(otu_df))]
  sintaxcol <- names(otu_df)[grepl("^SINTAX", names(otu_df))]
  # Extract taxonomic information and confidences for each level
  tmp_df <- otu_df %>%
    select(otucol, barcode_cols, sintaxcol) %>%
    mutate(
      domain = ifelse(str_detect(SINTAX, "d:"), str_extract(SINTAX, "d:[^,]+"), NA),
      domain_confidence = ifelse(is.na(domain), NA, as.numeric(str_extract(domain, "(?<=\\()\\d+\\.\\d+(?=\\))"))),
      domain = ifelse(is.na(domain), NA, str_replace(domain, "\\(.*\\)", "")), # Remove confidence scores and parentheses
      domain = ifelse(is.na(domain), NA, str_remove(domain, "d:")),  
      
      phylum = ifelse(str_detect(SINTAX, "p:"), str_extract(SINTAX, "p:[^,]+"), NA),
      phylum_confidence = ifelse(is.na(phylum), NA, as.numeric(str_extract(phylum, "(?<=\\()\\d+\\.\\d+(?=\\))"))),
      phylum = ifelse(is.na(phylum), NA, str_replace(phylum, "\\(.*\\)", "")), # Remove confidence scores and parentheses
      phylum = ifelse(is.na(phylum), NA, str_remove(phylum, "p:")),  
      
      class = ifelse(str_detect(SINTAX, "c:"), str_extract(SINTAX, "c:[^,]+"), NA),
      class_confidence = ifelse(is.na(class), NA, as.numeric(str_extract(class, "(?<=\\()\\d+\\.\\d+(?=\\))"))),
      class = ifelse(is.na(class), NA, str_replace(class, "\\(.*\\)", "")), # Remove confidence scores and parentheses
      class = ifelse(is.na(class), NA, str_remove(class, "c:")),
      
      order = ifelse(str_detect(SINTAX, "o:"), str_extract(SINTAX, "o:[^,]+"), NA),
      order_confidence = ifelse(is.na(order), NA, as.numeric(str_extract(order, "(?<=\\()\\d+\\.\\d+(?=\\))"))),
      order = ifelse(is.na(order), NA, str_replace(order, "\\(.*\\)", "")),
      order = ifelse(is.na(order), NA, str_remove(order, "o:")),
      
      family = ifelse(str_detect(SINTAX, "f:"), str_extract(SINTAX, "f:[^,]+"), NA),
      family_confidence = ifelse(is.na(family), NA, as.numeric(str_extract(family, "(?<=\\()\\d+\\.\\d+(?=\\))"))),
      family = ifelse(is.na(family), NA, str_replace(family, "\\(.*\\)", "")),
      family = ifelse(is.na(family), NA, str_remove(family, "f:")),
      
      genus = ifelse(str_detect(SINTAX, "g:"), str_extract(SINTAX, "g:[^,]+"), NA),
      genus_confidence = ifelse(is.na(genus), NA, as.numeric(str_extract(genus, "(?<=\\()\\d+\\.\\d+(?=\\))"))),
      genus = ifelse(is.na(genus), NA, str_replace(genus, "\\(.*\\)", "")),
      genus = ifelse(is.na(genus), NA, str_remove(genus, "g:")),
      
      species = ifelse(str_detect(SINTAX, "s:"), str_extract(SINTAX, "s:[^,]+"), NA),
      species_confidence = ifelse(is.na(species), NA, as.numeric(str_extract(species, "(?<=\\()\\d+\\.\\d+(?=\\))"))),
      species = ifelse(is.na(species), NA, str_replace(species, "\\(.*\\)", "")),
      species = ifelse(is.na(species), NA, str_remove(species, "s:"))
    )  %>% 
    mutate(across(all_of(barcode_cols), as.numeric)) %>%
    mutate(abundance = rowSums(across(all_of(barcode_cols)), na.rm = TRUE)) %>% 
    mutate( Include = (abundance == 1 & species_confidence >= 0.95) | (abundance > 1 & species_confidence >= 0.80)) %>%
    filter(Include) %>% 
      select(-Include) %>% 
    group_by(species) %>%
    summarize(across(all_of(barcode_cols), sum, na.rm = TRUE)) %>%
    ungroup()
  return(tmp_df)
}
