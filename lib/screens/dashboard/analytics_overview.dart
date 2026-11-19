import 'package:flutter/material.dart';
import '../../theme.dart';
import 'dashboard_models.dart';
class AnalyticsOverview extends StatelessWidget {
 const AnalyticsOverview({super.key,required this.summary});
 final AnalyticsSummary? summary;
 @override Widget build(BuildContext context){
   final s=summary;
   final entries=<({String name,int value,IconData icon,Color color})>[
    (name:'Total Readings',value:s?.total??0,icon:Icons.data_usage,color:AppColors.maroonMid),
    (name:'Fire-alert Samples',value:s?.fire??0,icon:Icons.local_fire_department,color:AppColors.red),
    (name:'Warning Samples',value:s?.warning??0,icon:Icons.warning_amber,color:AppColors.amber),
    (name:'Normal Reads',value:s?.normal??0,icon:Icons.check_circle_outline,color:AppColors.green),
   ];
   return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
     Text('Dual ESP32 Sensor Analytics',style:TextStyle(color:AppTheme.textPrimary(context),fontWeight:FontWeight.w900,fontSize:17)),
     const SizedBox(height:5),Text('Latest 1,000 readings from the updated firmware (smoke + flame confirmed fire, faulty sensors excluded). Readings saved before the false-fire fix are not counted.',style:TextStyle(color:AppTheme.textSecondary(context),fontSize:11)),
     const SizedBox(height:12),LayoutBuilder(builder:(context,c){final n=c.maxWidth>850?4:c.maxWidth>430?2:1;final w=(c.maxWidth-(n-1)*9)/n;
      return Wrap(spacing:9,runSpacing:9,children:entries.map((e)=>Container(width:w,padding:const EdgeInsets.all(15),decoration:GlassStyle.card(light:!AppTheme.isDark(context),border:e.color.withValues(alpha:.3)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Icon(e.icon,color:e.color),const SizedBox(height:13),Text('${e.value}',style:TextStyle(color:e.color,fontSize:25,fontWeight:FontWeight.w900)),Text(e.name,style:TextStyle(color:AppTheme.textSecondary(context),fontSize:11))]))).toList());
     }),
     const SizedBox(height:14),Container(padding:const EdgeInsets.all(15),decoration:GlassStyle.card(light:!AppTheme.isDark(context),border:AppTheme.border(context)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
       Text('Readings by Controller',style:TextStyle(color:AppTheme.textPrimary(context),fontWeight:FontWeight.w800)),const SizedBox(height:9),
       for(final id in ['ESP32-001','ESP32-002']) Padding(padding:const EdgeInsets.symmetric(vertical:6),child:Row(children:[Expanded(child:Text(id,style:TextStyle(color:AppTheme.textPrimary(context)))),Text('${s?.byDevice[id]??0} readings',style:TextStyle(color:AppTheme.textSecondary(context)))])),
       if(s?.total==0) Text('No readings from the updated firmware yet. Flash the new ESP32 sketch; counts start with its first upload.',style:TextStyle(color:AppTheme.textSecondary(context),fontSize:11)),
     ])),
     const SizedBox(height:14),
     Container(padding:const EdgeInsets.all(15),decoration:GlassStyle.card(light:!AppTheme.isDark(context),border:AppTheme.border(context)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
       Text('Incident Breakdown',style:TextStyle(color:AppTheme.textPrimary(context),fontWeight:FontWeight.w800)),const SizedBox(height:10),
       for(final row in <({String title,int count,Color color})>[
         (title:'Fire detected',count:s?.fire??0,color:AppColors.red),
         (title:'Warnings',count:s?.warning??0,color:AppColors.amber),
         (title:'Normal readings',count:s?.normal??0,color:AppColors.green),
       ]) Padding(padding:const EdgeInsets.symmetric(vertical:6),child:Column(children:[Row(children:[Expanded(child:Text(row.title,style:TextStyle(color:AppTheme.textPrimary(context),fontSize:11))),Text('${row.count} (${s==null||s.total==0?0:(row.count*100/s.total).round()}%)',style:TextStyle(color:row.color,fontWeight:FontWeight.w800,fontSize:11))]),const SizedBox(height:5),LinearProgressIndicator(value:s==null||s.total==0?0:row.count/s.total,minHeight:5,color:row.color,backgroundColor:AppTheme.border(context))])),
     ])),
   ]);
 }
}
