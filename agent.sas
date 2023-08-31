%macro run_agent(input =, dsmemory=, max_iter=2) ;
/*
  Run the agent.

  Parameters:
  - input (str): The input text provided to the agent for processing.
  - dsmemory (dataset): The name of the dataset used for storing chat history.
  - max_iter (int, optional): The maximum number of iterations within a turn.
    Defaults to 2, allowing for up to 1 tool usage and response per turn.
    
    Example usage:
    %run_agent(input=Hi., dsmemory=work.chat_history )
*/

  filename &chat_history. temp ;
  filename &agent_scratchpad. temp ;
  data _null_ ;
    file &agent_scratchpad. ;
  run ;

  %do i = 1 %to &max_iter. ;
    %let action = ;
    %let action_input = ;
    %let output = ;

    %memory(ds=&dsmemory., file = &chat_history.) ;
    %llm_chain ;
    %if %symexist(sys_prochttp_status_code) %then %do ;
      %if &sys_prochttp_status_code. ^= 200 %then %do ;
        %put ERROR: Expected 200, but received &sys_prochttp_status_code. ;
        %abort ;
      %end ;
    %end ;
    %parse ;

    %if &action. = output %then %do ;
      %memory(ds=&dsmemory.) ;
      %goto exit ;
    %end ;
    %else %if &action. ne %then %executor ;
    %else %do ;
      %put ERROR: Could not parse LLM output. ;
      %abort ;
    %end ;
  %end ;

  %put NOTE: Chain Stopped. ;

  %exit:
%mend ;

%macro llm_chain ;
/* Chain that formats a prompt and calls a LLM. */
  filename tpl temp ;
  filename pprint temp ; /* pretty print */
  filename prompt temp ;

  proc stream outfile = tpl ;
begin &streamdelim.;
&streamdelim. readfile &prefix. ;
&streamdelim. readfile tools ;
&streamdelim. readfile &format_instraction. ;
&streamdelim. readfile &suffix. ;
;;;;
  run ;
  
  data _null_ ;
    infile tpl ;
    file prompt ;
    input ;
    put _infile_ ' &streamdelim. newline;' ;
  run ;
  
  proc stream outfile = pprint ;
begin &streamdelim.;
&streamdelim.;%include prompt ;
;;;;
  run ;

/* Escaping and Line Break */
  data _null_ ;
    file prompt ;
    infile pprint ;
    length text $32767 ;
    input ;
    text = prxchange('s/(?<!\\)"/\"/', -1, _infile_) ;
    len = lengthn(text) ;
    put text $varying. len '\n' ;
  run ;

  filename payload temp ;
  proc stream outfile = payload quoting = both ;
begin &streamdelim.;
{&llm., "stop": ["\nObservation:","\n\tObservation:"], "messages" : [{"role": "user", "content": &streamdelim.;"%include prompt;"}]}
;;;;
  run ;

/* call a LLM. */
  filename response temp ;
  
  proc http url = "https://api.openai.com/v1/chat/completions"
            method = "POST"
            in = payload 
            out = response
            ;
            headers "Content-type" = "application/json"
                    "Accept" = "application/json"
                    "Authorization" = "Bearer &api_key."
                    ;
  run ;
%mend ;

%macro parse ;
/* Output parser for the agent. */
  libname response json fileref = response ;
  filename content temp ;
  
  data _null_ ;
    file content ;
    set response.choices_message ;
    put content ;
  run ;

  data _null_;
    infile content end=eof;
    length text $32767;
    retain outflg 0 text "";
    input;
    if prxmatch("/&ai_prefix.:/",_infile_) > 0 then do ; 
      outflg = 1 ; 
      call symputx("action", "output") ;
    end ;
    else if prxmatch("/Action:/",_infile_) > 0       then call symputx("action", _infile_ ) ;
    else if prxmatch("/Action Input:/",_infile_) > 0 then call symputx("action_input", _infile_ ) ;

    if outflg = 1 then text = catx("0a"x, text, _infile_) ;

    if eof = 1 and outflg = 1 then do ;
      call symputx('output',text) ;
    end ;
  run;
%mend ;

%macro memory(ds=, file=) ;
/*
  Store or export the memory of a conversation.

  Parameters:
  - ds (dataset): The name of the dataset where the memory will be stored or used as a source.
  - file (filename): Filename where the memory will be exported.
*/

  %if &file. ne %then %do ;
    data _null_ ;
      file &file. ;
      set &ds. ;
      array char _character_ ;
      do over char ;
        role = strip(vname(char)) ;
        put role +(-1) ":" char ;
      end ;
    run ;
  %end ;
  %else %do ; 
    proc sql noprint ;
      select count(*) into: nobs from &ds. ;
    quit ;
   
    data &ds. ;
    %if %eval(&nobs. > 0 ) %then %do ;
      set &ds. end = eof ;
      output ;
      if eof = 1 then do ;
        &human_prefix. = "&input." ;
        &ai_prefix. = transtrn("&output.", "&ai_prefix.: ", "") ;
        output ;
      end ;
   %end ;
   %else %do ;
      if 0 then set &ds. ;
      &human_prefix. = "&input." ;
      &ai_prefix. = transtrn("&output.", "&ai_prefix.: ", "") ;
      output ;
   %end ;
    run ;
  %end ;
%mend ;
  
%macro executor ;
/* Agent that is using tools. */
  filename &agent_scratchpad. temp ;

  data _null_ ;
    infile content ;
    input ;
    if prxmatch("/Action: /", _infile_) > 0 then call symputx("action", substr(_infile_, 9)) ;
    else if prxmatch("/Action Input: /", _infile_) > 0 then call symputx("action_input", substr(_infile_, 14)) ;
  run ;
  %let observation = ;
  %&action.(&action_input.) ;
  
  proc stream outfile= &agent_scratchpad. ;
begin &streamdelim.;
&streamdelim. readfile content ;
Observation: &observation.
;;;;
  run ;
  
%mend ;